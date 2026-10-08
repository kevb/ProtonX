// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
// Appended inside package papi by the deterministic native materializer.
type calendarTransport struct { base *http.Transport; origin *url.URL }
func nativeTransport(baseURL string) http.RoundTripper {
 t:=http.DefaultTransport.(*http.Transport).Clone(); t.Proxy=nil
 t.ResponseHeaderTimeout=30*time.Second
 origin,_:=url.Parse(baseURL); return calendarTransport{t,origin}
}
func (t calendarTransport) RoundTrip(req *http.Request) (*http.Response,error) {
 if t.origin==nil || req.URL.Host!=t.origin.Host || req.URL.Scheme!=t.origin.Scheme || req.URL.User!=nil {return nil,errors.New("Calendar origin refused")}
 response,err:=t.base.RoundTrip(req)
 // Refuse redirects before either HTTP client can forward auth to a new request.
 if err==nil && response.StatusCode>=300 && response.StatusCode<400 {response.Body.Close();return nil,errors.New("Calendar redirect refused")}
 if err==nil {response.Body=struct{io.Reader;io.Closer}{io.LimitReader(response.Body,(8<<20)+1),response.Body}}
 return response,err
}
