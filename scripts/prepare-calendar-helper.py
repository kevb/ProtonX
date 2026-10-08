#!/usr/bin/env python3
"""Materialize an exact source pin. Account data is never read by build scripts."""
import pathlib, json, subprocess, shutil, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
pin = next(
    s
    for s in json.loads((root / "upstream.lock.json").read_text())["sources"]
    if s["name"] == "proton-cal"
)
source = root / "upstream/proton-cal"
dest = root / ".tools/calendar-native"
# Refuse edits to the upstream pin instead of applying a patch to unknown code.
if subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=source, text=True
).strip() != pin["revision"] or subprocess.check_output(
    ["git", "status", "--porcelain"], cwd=source
):
    raise SystemExit("Calendar source differs from its clean pin")
with tempfile.TemporaryDirectory(prefix="ProtonX-calendar-source-") as tmp:
    stage = pathlib.Path(tmp)
    subprocess.run(
        ["git", "archive", "HEAD", "-o", str(stage / "source.tar")],
        cwd=source,
        check=True,
    )
    subprocess.run(
        ["tar", "-xf", str(stage / "source.tar"), "-C", str(stage)], check=True
    )
    (stage / "source.tar").unlink()
    shutil.copy2(root / "Resources/CalendarHelper.mod", stage / "go.mod")
    shutil.copy2(root / "Resources/CalendarHelper.sum", stage / "go.sum")
    shutil.copy2(
        root / "Tools/ProtonXCalendarHelper/config_native.go",
        stage / "pkg/config/config.go",
    )
    helper = stage / "cmd/protonx-calendar"
    helper.mkdir()
    for file in (root / "Tools/ProtonXCalendarHelper").glob("*.go"):
        if file.name != "config_native.go":
            shutil.copy2(file, helper / file.name)
    for package in ("event", "calendar"):
        test = (
            (root / "Tools/CalendarContractTests/storage_test.go")
            .read_text()
            .replace("package PACKAGE", "package " + package)
        )
        (stage / "pkg" / package / "protonx_storage_test.go").write_text(test)
    # CAPTCHA console/paste workarounds and arbitrary browser URLs are excluded.
    auth = stage / "pkg/auth/auth.go"
    s = auth.read_text()
    s = s.replace('\n\t"github.com/pkg/browser"', "")
    start = s.index("func captchaToken(")
    end = s.index("// isInsufficientScope", start)
    s = (
        s[:start]
        + 'func captchaToken(Prompter, string) (string,error) { return "",errors.New("verification_required") }\n\n'
        + s[end:]
    )
    auth.write_text(s)
    api = stage / "pkg/papi/papi.go"
    s = api.read_text().replace(
        'UserAgent = "proton-cal/0.1"', 'UserAgent = "ProtonX-Calendar/0.1"'
    )
    s = s.replace(
        "proton.WithLogger(quietLogger{}),",
        "proton.WithLogger(quietLogger{}), proton.WithTransport(nativeTransport(baseURL)),",
    )
    s = s.replace(
        "&http.Client{Timeout: 60 * time.Second}",
        '&http.Client{Timeout: 45 * time.Second, Transport: nativeTransport(baseURL), CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect refused") }}',
    )
    s = s.replace(
        "io.LimitReader(res.Body, 64<<20)", "io.LimitReader(res.Body, (8<<20)+1)"
    )
    s = s.replace(
        "resp.retryAfter = res.Header",
        'if len(resp.raw) > 8<<20 { return 0, resp, errors.New("response too large") }; resp.retryAfter = res.Header',
    )
    s = s.replace(
        "sess config.Session // cached tokens;",
        "storageErr error\n\tsess config.Session // cached tokens;",
    )
    s = s.replace(
        "_ = store.UpdateTokens(auth.UID, auth.AccessToken, auth.RefreshToken)",
        "if err:=store.UpdateTokens(auth.UID, auth.AccessToken, auth.RefreshToken); err!=nil { c.mu.Lock(); c.storageErr=config.ErrStorage; c.mu.Unlock(); return }",
    )
    s = s.replace(
        "_ = store.Clear()",
        "if err:=store.Clear(); err!=nil { c.mu.Lock(); c.storageErr=config.ErrStorage; c.mu.Unlock(); return }",
    )
    s = s.replace(
        "if c.sess.Valid() {",
        "if c.storageErr!=nil {return config.Session{},c.storageErr}; if c.sess.Valid() {",
    )
    s = s.replace(
        "if status < 200 || status >= 300 {",
        'if status < 200 || status >= 300 || (respBody.envelope.Code!=0 && respBody.envelope.Code!=CodeSuccess && respBody.envelope.Code!=CodeSuccessMulti) || (respBody.envelope.Code==0 && c.baseURL==config.DefaultBaseURL && len(path)>=10 && path[:10]=="/calendar/") {',
    )
    s += "\n" + (root / "Tools/CalendarContractTests/transport.go").read_text()
    api.write_text(s)
    shutil.copy2(
        root / "Tools/CalendarContractTests/transport_test.go",
        stage / "pkg/papi/protonx_transport_test.go",
    )
    # Bound server paging, raw rows and malformed recurrence instead of silent loss.
    wire = stage / "pkg/event/wire.go"
    s = wire.read_text().replace(
        "for page := 0; ; page++ {",
        'for page := 0; ; page++ {\n if page >= 50 { return nil, fmt.Errorf("Calendar page limit") }',
    )
    s = s.replace(
        "all = append(all, resp.Events...)",
        'if len(resp.Events)>100 || len(all)+len(resp.Events)>5000 { return nil, fmt.Errorf("Calendar event limit") }; all = append(all, resp.Events...)',
    )
    s = s.replace(
        "out = append(out, ev)",
        'out = append(out, ev); if len(out)>5000 { return nil,fmt.Errorf("Calendar event limit") }',
    )
    wire.write_text(s)
    exp = stage / "pkg/recurrence/expand.go"
    s = exp.read_text().replace(
        "for {\n\t\toccDt, ok := next()",
        'for iteration:=0; ; iteration++ {\n if iteration>=200000 { return nil,fmt.Errorf("Calendar recurrence limit") };\n\t\toccDt, ok := next()',
    )

    s = s.replace(
        "for _, ev := range events {\n\t\tswitch {",
        "for _, ev := range events {\n if len(results)>5000 { return results };\n\t\tswitch {",
    )
    # Preserve legacy public tests, but expose a strict reader which never silently
    # falls back to a master row or truncates a recurrence/date window.
    strict = s[s.index("func ExpandOccurrences(") : s.index("// ResolveOccurrence")]
    strict = strict.replace(
        "func ExpandOccurrences(", "func ExpandOccurrencesStrict("
    ).replace(") []Occurrence {", ") ([]Occurrence,error) {", 1)
    strict = strict.replace(
        "if len(results)>5000 { return results }",
        'if len(results)>5000 { return nil,fmt.Errorf("Calendar recurrence limit") }',
    )
    old = "results = appendIfOverlapping(results, ev, start, end)\n\t\t\t\tcontinue"
    strict = strict.replace(old, "return nil,err")
    strict = strict.replace(
        "results = append(results, occs...)",
        'if len(occs)>=maxOccurrencesPerMaster { return nil,fmt.Errorf("Calendar recurrence limit") }; results = append(results, occs...)',
    )
    strict = strict.replace(
        "return results\n}",
        'if len(results)>5000 {return nil,fmt.Errorf("Calendar recurrence limit")}; return results,nil\n}',
    )
    s += "\n" + strict
    decrypt = stage / "pkg/event/decrypt.go"
    d = decrypt.read_text().replace(
        "occs := recurrence.ExpandOccurrences(raws, start, end)",
        "occs,err := recurrence.ExpandOccurrencesStrict(raws, start, end); if err!=nil {return nil,err}",
    )
    decrypt.write_text(d)
    exp.write_text(s)
    keys = stage / "pkg/calendar/keys.go"
    keys.write_text(
        keys.read_text()
        + "\nfunc (k *Keychain) Clear() { k.mu.Lock(); defer k.mu.Unlock(); for id,a:=range k.cache {a.KR.ClearPrivateParams();delete(k.cache,id)} }\n"
    )
    # Reader rejects degraded decryption in its own projection; no partial event is exposed.
    expected = {p.relative_to(stage) for p in stage.rglob("*") if p.is_file()}
    existing = {p.relative_to(dest) for p in dest.rglob("*") if p.is_file()}
    if existing - expected:
        raise SystemExit(
            "Unexpected Calendar build inputs; preserve the tree before retrying"
        )
    for rel in expected:
        target = dest / rel
        file = stage / rel
        if target.exists() and target.read_bytes() == file.read_bytes():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
print(dest)
