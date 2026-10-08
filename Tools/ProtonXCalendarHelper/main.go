// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
// Native bounded Calendar adapter. Proton libraries own SRP, key unlocking and PGP.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/cheeseandcereal/proton-cal/pkg/auth"
	"github.com/cheeseandcereal/proton-cal/pkg/calendar"
	"github.com/cheeseandcereal/proton-cal/pkg/caltypes"
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"github.com/cheeseandcereal/proton-cal/pkg/event"
	"github.com/cheeseandcereal/proton-cal/pkg/papi"
	"github.com/teambition/rrule-go"
)

const maxInput = 64 * 1024
const maxOutput = 8 * 1024 * 1024

var errInput = errors.New("invalid_input")
var errReadOnly = errors.New("read_only")

type command struct {
	Method   string          `json:"method"`
	Handoff  *accountHandoff `json:"handoff,omitempty"`
	Username string          `json:"username,omitempty"`
	Password string          `json:"password,omitempty"`
	Code     string          `json:"code,omitempty"`
	Start    int64           `json:"start,omitempty"`
	End      int64           `json:"end,omitempty"`
	Zone     string          `json:"zone,omitempty"`
	Draft    *draft          `json:"draft,omitempty"`
}
type packet struct {
	Schema  int     `json:"schema"`
	ID      uint64  `json:"id"`
	Command command `json:"command"`
}
type reply struct {
	Schema  int    `json:"schema"`
	ID      uint64 `json:"id"`
	Result  any    `json:"result,omitempty"`
	Failure string `json:"failure,omitempty"`
}
type collection struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Color    int    `json:"color"`
	Writable bool   `json:"writable"`
}
type day struct {
	Year  int `json:"year"`
	Month int `json:"month"`
	Day   int `json:"day"`
}
type record struct {
	ID         string `json:"id"`
	CalendarID string `json:"calendarID"`
	Title      string `json:"title"`
	Location   string `json:"location"`
	Notes      string `json:"notes"`
	Start      int64  `json:"start"`
	End        int64  `json:"end"`
	Zone       string `json:"zone"`
	AllDay     bool   `json:"allDay"`
	StartDay   *day   `json:"startDay,omitempty"`
	EndDay     *day   `json:"endDay,omitempty"`
	Recurring  bool   `json:"recurring"`
	WriteToken string `json:"writeToken,omitempty"`
}
type result struct {
	Phase     string       `json:"phase,omitempty"`
	Calendars []collection `json:"calendars"`
	Events    []record     `json:"events"`
	Start     int64        `json:"start,omitempty"`
	End       int64        `json:"end,omitempty"`
	Omitted   int          `json:"omitted,omitempty"`
}

// Event drafts are confined to save_event. No files, host overrides or exports.
func decode(line []byte) (packet, error) {
	var p packet
	d := json.NewDecoder(bytes.NewReader(line))
	d.DisallowUnknownFields()
	if len(line) > maxInput || d.Decode(&p) != nil || p.Schema != 1 || p.ID == 0 {
		return p, errInput
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return p, errInput
	}
	c := p.Command
	if c.Method != "save_event" && c.Draft != nil {
		return p, errInput
	}
	if c.Method != "account_handoff" && c.Handoff != nil {
		return p, errInput
	}
	switch c.Method {
	case "login":
		if c.Username == "" || len(c.Username) > 320 || c.Password == "" || len(c.Password) > 4096 || c.Code != "" || c.Start != 0 || c.End != 0 || c.Zone != "" || strings.ContainsAny(c.Username, "\r\n\x00") {
			return p, errInput
		}
	case "totp":
		if len(c.Code) < 6 || len(c.Code) > 8 || strings.Trim(c.Code, "0123456789") != "" || c.Username != "" || c.Password != "" || c.Start != 0 || c.End != 0 || c.Zone != "" {
			return p, errInput
		}
	case "mailbox_password":
		if c.Password == "" || len(c.Password) > 4096 || c.Username != "" || c.Code != "" || c.Start != 0 || c.End != 0 || c.Zone != "" {
			return p, errInput
		}
	case "save_event":
		if c.Draft == nil || c.Draft.validate() != nil || c.Username != "" || c.Password != "" || c.Code != "" || c.Start != 0 || c.End != 0 || c.Zone != "" {
			return p, errInput
		}
	case "snapshot":
		if c.Username != "" || c.Password != "" || c.Code != "" || c.Start < 0 || c.End <= c.Start || c.End-c.Start > 62*86400 || c.End > 7289654400 || len(c.Zone) > 128 {
			return p, errInput
		}
		if _, err := time.LoadLocation(c.Zone); err != nil {
			return p, errInput
		}
	case "account_handoff":
		if !c.Handoff.valid(time.Now().Unix()) || c.Username != "" || c.Password != "" || c.Code != "" || c.Start != 0 || c.End != 0 || c.Zone != "" {
			return p, errInput
		}
	case "restore", "sign_out", "commit_handoff":
		if c.Username != "" || c.Password != "" || c.Code != "" || c.Start != 0 || c.End != 0 || c.Zone != "" {
			return p, errInput
		}
	default:
		return p, errInput
	}
	return p, nil
}

type memoryBackend struct{ data []byte }

func (b *memoryBackend) Read() ([]byte, error) {
	if len(b.data) == 0 {
		return nil, config.ErrNoSession
	}
	return append([]byte(nil), b.data...), nil
}
func (b *memoryBackend) Write(d []byte) error {
	clear(b.data)
	b.data = append([]byte(nil), d...)
	return nil
}
func (b *memoryBackend) Delete() error { clear(b.data); b.data = nil; return nil }

type engine struct {
	input          *bufio.Scanner
	output         io.Writer
	id             uint64
	client         *papi.Client
	keys           *calendar.Keychain
	unlocked       *auth.Unlocked
	backend        config.Backend
	pending        *engine
	handoffExpires int64
	redeem         func(context.Context, string) (papi.CalendarFork, error)
	unlockHandoff  func(context.Context, *engine) error
	writeAPI       papi.API // injected only by synthetic tests
	scope          map[string]editScope
	collections    map[string]bool
	writeBlocked   bool
}

func (e *engine) send(value any, failure string) error {
	b, err := json.Marshal(reply{Schema: 1, ID: e.id, Result: value, Failure: failure})
	if err != nil || len(b) > maxOutput {
		b, _ = json.Marshal(reply{Schema: 1, ID: e.id, Failure: "too_large"})
	}
	b = append(b, '\n')
	_, err = e.output.Write(b)
	return err
}
func (e *engine) close() {
	e.scope = nil
	e.collections = nil
	e.writeBlocked = false
	e.clearHandoff()
	if e.keys != nil {
		e.keys.Clear()
	}
	if e.client != nil {
		e.client.Close()
		e.client = nil
	}
	if e.unlocked != nil {
		for _, kr := range e.unlocked.AddrKRs {
			kr.ClearPrivateParams()
		}
		e.unlocked = nil
	}
	e.keys = nil
}
func (e *engine) restore(ctx context.Context) error {
	e.close()
	config.SetBackend(e.backend)
	store, _ := config.NewSessionStore()
	sess, err := store.Load()
	if err != nil {
		return err
	}
	if len(sess.SaltedKeyPass) == 0 {
		return config.ErrStorage
	}
	client, err := papi.FromSession(store, config.DefaultBaseURL)
	if err != nil {
		return err
	}
	unlocked, err := auth.UnlockKeys(ctx, store, client)
	if err != nil {
		client.Close()
		return err
	}
	e.client = client
	e.unlocked = unlocked
	e.keys = calendar.NewKeychain(readAPI{client}, unlocked)
	return nil
}

// During login only, credentials/challenges travel on the same private pipe.
// Prompt text/raw errors are never sent or logged. Unsupported verification ends.
type prompter struct {
	e        *engine
	password string
}

func (p *prompter) Notify(string) {}
func (p *prompter) Prompt(label string) (string, error) {
	if label != "2FA code" {
		return "", errors.New("verification_required")
	}
	return p.challenge("totp")
}
func (p *prompter) PromptSecret(label string) (string, error) {
	if label == "Password" {
		v := p.password
		p.password = ""
		return v, nil
	}
	if label == "Mailbox password" {
		return p.challenge("mailbox_password")
	}
	return "", errInput
}
func (p *prompter) challenge(phase string) (string, error) {
	if err := p.e.send(result{Phase: phase}, ""); err != nil {
		return "", err
	}
	if !p.e.input.Scan() {
		return "", context.Canceled
	}
	next, err := decode(p.e.input.Bytes())
	if err != nil {
		return "", err
	}
	p.e.id = next.ID
	if next.Command.Method != phase {
		return "", errInput
	}
	if phase == "totp" {
		return next.Command.Code, nil
	}
	return next.Command.Password, nil
}

// Adapter-side read-only fence. Even linked upstream mutation routines cannot
// issue a Calendar write through the API provided to event/key code.
type readAPI struct{ papi.API }

func (a readAPI) Get(ctx context.Context, path string, q url.Values, out any) error {
	if !readPath(path) {
		return errReadOnly
	}
	if err := a.API.Get(ctx, path, q, out); err != nil {
		return err
	}
	if strings.HasSuffix(path, "/events") {
		b, err := json.Marshal(out)
		if err != nil || len(b) > 8<<20 {
			return errors.New("too_large")
		}
		var page struct{ Events []*caltypes.RawEvent }
		if json.Unmarshal(b, &page) != nil {
			return errInput
		}
		calID := strings.TrimSuffix(strings.TrimPrefix(path, "/calendar/v1/"), "/events")
		if err := validateRows(page.Events, calID); err != nil {
			return err
		}
	}
	return nil
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_+=-]{1,128}$`)

func readPath(path string) bool {
	if path == "/calendar/v1" {
		return true
	}
	parts := strings.Split(path, "/")
	if len(parts) != 5 || parts[0] != "" || parts[1] != "calendar" || !identifier.MatchString(parts[3]) {
		return false
	}
	return (parts[2] == "v1" && parts[4] == "events") || (parts[2] == "v2" && parts[4] == "bootstrap")
}
func validateRows(rows []*caltypes.RawEvent, calendarID string) error {
	if len(rows) > 100 {
		return errors.New("too_large")
	}
	for _, r := range rows {
		if r == nil || r.ID == "" || len(r.ID) > 128 || r.CalendarID != calendarID || r.StartTime < 0 || r.EndTime <= r.StartTime || r.EndTime > 7289654400 || r.EndTime-r.StartTime > 366*86400 || len(r.Exdates) > 5000 || len(r.RRule) > 1024 {
			return errInput
		}
		if r.RRule != "" {
			loc, err := time.LoadLocation(r.StartTimezone)
			if r.StartTimezone == "" || r.IsAllDay() {
				loc = time.UTC
				err = nil
			}
			if err != nil {
				return errInput
			}
			o, err := rrule.StrToROptionInLocation(r.RRule, loc)
			if err != nil {
				return errInput
			}
			o.Dtstart = time.Unix(r.StartTime, 0).In(loc)
			if _, err = rrule.NewRRule(*o); err != nil {
				return errInput
			}
		}
	}
	return nil
}
func (readAPI) Put(context.Context, string, any, any) error  { return errReadOnly }
func (readAPI) Post(context.Context, string, any, any) error { return errReadOnly }
func (readAPI) Delete(context.Context, string, any) error    { return errReadOnly }
func (e *engine) handle(ctx context.Context, c command) (any, error) {
	switch c.Method {
	case "account_handoff":
		return e.stageHandoff(ctx, c.Handoff)
	case "commit_handoff":
		return e.commitHandoff(ctx)
	case "login":
		e.close()
		staging := &memoryBackend{}
		config.SetBackend(staging)
		_, err := auth.Login(ctx, &prompter{e: e, password: c.Password}, config.Config{Username: c.Username})
		c.Password = ""
		if err != nil {
			staging.Delete()
			config.SetBackend(e.backend)
			return nil, err
		}
		data, err := staging.Read()
		if err != nil {
			return nil, err
		}
		err = e.backend.Write(data)
		clear(data)
		staging.Delete()
		config.SetBackend(e.backend)
		if err != nil {
			return nil, err
		}
		if err = e.restore(ctx); err != nil {
			return nil, err
		}
		return result{Phase: "connected"}, nil
	case "restore":
		if err := e.restore(ctx); err != nil {
			return nil, err
		}
		return result{Phase: "connected"}, nil
	case "sign_out":
		if e.client == nil {
			return nil, errors.New("invalid_state")
		}
		if err := e.client.Proton().AuthDelete(ctx); err != nil {
			return nil, err
		}
		e.close()
		config.SetBackend(e.backend)
		store, _ := config.NewSessionStore()
		if err := store.Clear(); err != nil {
			return nil, err
		}
		return result{Phase: "welcome"}, nil
	case "save_event":
		return e.saveEvent(ctx, c.Draft)
	case "snapshot":
		if e.client == nil {
			return nil, errors.New("invalid_state")
		}
		return e.snapshot(ctx, c)
	default:
		return nil, errInput
	}
}
func civil(t time.Time) *day {
	t = t.UTC()
	return &day{Year: t.Year(), Month: int(t.Month()), Day: t.Day()}
}
func project(listed event.Listed, calendarID string) (record, error) {
	ev := listed.Event
	occ := listed.Occurrence
	if ev == nil || ev.DecryptFailed || ev.CalendarID != calendarID || len(ev.Summary) > 512 || len(ev.Location) > 1024 || len(ev.Description) > 16384 || strings.ContainsAny(ev.Summary, "\r\n\x00") || occ.Start < 0 || occ.End <= occ.Start || occ.End-occ.Start > 366*86400 {
		return record{}, errors.New("decryption_failed")
	}
	title := strings.TrimSpace(ev.Summary)
	if title == "" {
		title = "Untitled event"
	}
	zone := ev.StartTimezone
	if zone == "" {
		zone = "UTC"
	}
	if _, err := time.LoadLocation(zone); err != nil {
		return record{}, err
	}
	hash := sha256.Sum256([]byte(calendarID + "\x00" + ev.EventID + "\x00" + strconv.FormatInt(occ.Start, 10)))
	r := record{ID: hex.EncodeToString(hash[:]), CalendarID: calendarID, Title: title, Location: ev.Location, Notes: ev.Description, Start: occ.Start, End: occ.End, Zone: zone, AllDay: ev.AllDay, Recurring: ev.RRule != "" || !ev.RecurrenceID.IsZero()}
	if r.AllDay {
		if r.Start%86400 != 0 || r.End%86400 != 0 {
			return record{}, errInput
		}
		r.StartDay = civil(time.Unix(r.Start, 0))
		r.EndDay = civil(time.Unix(r.End, 0))
	}
	return r, nil
}
func (e *engine) snapshot(ctx context.Context, c command) (any, error) {
	infos, err := calendar.List(ctx, readAPI{e.client})
	if err != nil {
		return nil, err
	}
	if len(infos) > 64 {
		return nil, errors.New("too_large")
	}
	scope := map[string]editScope{}
	collections := map[string]bool{}
	out := result{Phase: "connected", Calendars: make([]collection, 0, len(infos)), Events: []record{}, Start: c.Start, End: c.End}
	for i, info := range infos {
		if !identifier.MatchString(info.ID) || len(info.Name) > 512 {
			return nil, errInput
		}
		out.Calendars = append(out.Calendars, collection{ID: info.ID, Name: info.Name, Color: i % 6, Writable: e.owned(info)})
		collections[info.ID] = e.owned(info)
		access, err := e.keys.Unlock(ctx, info)
		if err != nil {
			return nil, err
		}
		listed, err := event.ListWindow(ctx, readAPI{e.client}, access.KR, info.ID, c.Start, c.End, c.Zone)
		if err != nil {
			return nil, err
		}
		for _, l := range listed {
			r, err := project(l, info.ID)
			if err != nil {
				out.Omitted++
				continue
			}
			if collections[info.ID] && editable(l.Event, l.Occurrence.Event) && verifyCards(l.Occurrence.Event, access) == nil {
				r.WriteToken = fingerprint(l.Occurrence.Event)
				scope[r.ID] = editScope{calendarID: info.ID, eventID: l.Event.EventID, token: r.WriteToken}
			}
			out.Events = append(out.Events, r)
			if len(out.Events) > 5000 {
				return nil, errors.New("too_large")
			}
		}
	}
	e.scope = scope
	e.collections = collections
	e.writeBlocked = false
	return out, nil
}
func failure(err error) string {
	if errors.Is(err, errConflict) {
		return "conflict"
	}
	if errors.Is(err, errUncertain) {
		return "write_uncertain"
	}
	if errors.Is(err, errReadOnly) {
		return "read_only"
	}
	if errors.Is(err, errHandoff) {
		return "handoff_unavailable"
	}
	if errors.Is(err, config.ErrNoSession) {
		return "session_expired"
	}
	if errors.Is(err, config.ErrStorage) {
		return "storage_unavailable"
	}
	if errors.Is(err, errInput) {
		return "invalid_input"
	}
	var api *papi.Error
	if errors.As(err, &api) && api.Status == 401 {
		return "session_expired"
	}
	var official *proton.APIError
	if errors.As(err, &official) && official.Status == 401 {
		return "session_expired"
	}
	if strings.Contains(err.Error(), "verification_required") || strings.Contains(err.Error(), "FIDO2") {
		return "verification_required"
	}
	if strings.Contains(err.Error(), "limit") || strings.Contains(err.Error(), "too large") || strings.Contains(err.Error(), "too_large") {
		return "too_large"
	}
	return "operation_failed"
}
func serve(in io.Reader, out io.Writer, backend config.Backend) {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), maxInput)
	e := engine{input: scanner, output: out, backend: backend}
	defer e.close()
	for scanner.Scan() {
		p, err := decode(scanner.Bytes())
		e.id = p.ID
		if err != nil {
			e.send(nil, "invalid_input")
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
		value, err := e.handle(ctx, p.Command)
		cancel()
		if err != nil {
			if failure(err) == "session_expired" {
				e.close()
			}
			if e.send(nil, failure(err)) != nil {
				return
			}
		} else if e.send(value, "") != nil {
			return
		}
	}
}

// Only a dedicated Calendar lock file is created. Sessions/events never enter it.
func profileLock() (*os.File, error) {
	path := os.Getenv("PROTONX_CALENDAR_DIR")
	if path == "" {
		return nil, errInput
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errInput
	}
	fd, err := syscall.Open(path+"/.helper-lock", syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "Calendar profile lock")
	stat, err := f.Stat()
	if err != nil || !stat.Mode().IsRegular() || stat.Mode().Perm() != 0600 || stat.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		f.Close()
		return nil, config.ErrStorage
	}
	if syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		f.Close()
		return nil, config.ErrStorage
	}
	return f, nil
}
func main() {
	if len(os.Args) != 1 {
		return
	}
	f, err := profileLock()
	if err != nil {
		return
	}
	defer f.Close()
	serve(os.Stdin, os.Stdout, keychainBackend{})
}
