// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ProtonXCore

private let calendarColors: [Color] = [.purple, .blue, .pink, .orange, .green, .teal]

struct CalendarWindow: View {
    @ObservedObject var store: CalendarStore
    var isActive = true
    var accounts: [SuiteWorkspace.CalendarAccountOption] = []
    var connectAccount: (ProductRoute) -> Void = { _ in }
    var useAnotherAccount: () -> Void = {}
    @State private var separateAccount = false
    @FocusState private var searchFocused: Bool
    @State private var deletion: CalendarStore.DeleteIntent?
    @State private var username = ""
    @State private var password = ""
    @State private var challenge = ""
    private var zone: TimeZone { store.math.calendar.timeZone }
    var body: some View {
        Group {
            if !store.isWorkspaceOpen { welcome }
            else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 210)
                    Divider()
                    VStack(spacing: 0) {
                        header
                        Divider()
                        if let error = store.error {
                            Text(error).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity)
                        }
                        switch store.mode {
                        case .week: CalendarWeekView(store: store)
                        case .month: CalendarMonthView(store: store)
                        case .agenda: CalendarAgendaView(store: store)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let editor = store.editor {
                        Divider()
                        CalendarEditorView(store: store, editor: editor).frame(width: 300)
                    } else if let event = store.selectedEvent {
                        Divider()
                        inspector(event).frame(width: 280)
                    }
                }
            }
        }.background(PassTheme.canvas).environment(\.timeZone, zone)
            .onChange(of: isActive) { _, active in if !active { password = ""; challenge = ""; if store.phase == .signingIn || store.phase == .totp || store.phase == .mailboxPassword { store.lock() } } }
            .onChange(of: store.phase) { _, _ in password = ""; challenge = "" }
            .onReceive(NotificationCenter.default.publisher(for: .protonXNewEvent)) { _ in if isActive { store.beginEvent() } }
            .onReceive(NotificationCenter.default.publisher(for: .protonXFocusCalendarSearch)) { _ in if isActive { searchFocused = true } }
            .alert("Delete this preview event?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("Cancel", role: .cancel) { deletion = nil }
                Button("Delete event", role: .destructive) { if let deletion { store.delete(deletion) }; deletion = nil }
            } message: { Text(deletion?.title ?? "") }
    }
    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar").font(.system(size: 56, weight: .light)).foregroundStyle(PassTheme.accent)
                .frame(width: 116, height: 116).background(PassTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            if store.phase == .locked {
                LocalUnlockCard(product:"Calendar",authentication:store.localAuthentication,isActive:isActive,busy:store.busy,
                                unlock:{ store.unlock(mode:$0) },cancel:{ store.lock() })
            } else if store.phase == .signingIn {
                Text("Connecting your Calendar").font(.title.weight(.semibold))
                ProgressView().controlSize(.large)
                Button("Cancel") { store.lock() }
            } else if store.phase == .totp || store.phase == .mailboxPassword {
                Text(store.phase == .totp ? "Verify your account" : "Unlock your Calendar keys").font(.title.weight(.semibold))
                Text(store.phase == .totp ? "Enter the code from your authenticator." : "Enter your Proton mailbox password.").foregroundStyle(.secondary)
                SecureField(store.phase == .totp ? "Verification code" : "Mailbox password",text:$challenge).textFieldStyle(.roundedBorder)
                    .frame(width:320).onSubmit { submitChallenge() }.accessibilityIdentifier("calendarChallenge")
                Button("Continue") { submitChallenge() }.buttonStyle(.borderedProminent).disabled(store.busy || challenge.isEmpty)
                Button("Cancel") { store.lock() }
            } else {
                Text("Your Calendar, at home on Mac").font(.largeTitle.weight(.semibold))
                Text(store.previewOnly ? "Explore a native Calendar with sample events." : "Read your calendars using your Proton account.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if !store.previewOnly && !accounts.isEmpty && !separateAccount {
                    VStack(spacing:12) {
                        Text("Continue with an account in ProtonX").font(.headline)
                        ForEach(accounts) { account in
                            Button { connectAccount(account.product) } label: {
                                HStack(spacing:12) {
                                    Image(systemName:account.needsUnlock ? "touchid" : account.product == .mail ? "envelope" : "key")
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(!account.canContinue ? "Waiting for \(account.product.displayName)…" : account.needsUnlock ? "Unlock \(account.product.displayName) to continue" : "Connect with \(account.product.displayName)").fontWeight(.medium)
                                        Text(account.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName:"arrow.right")
                                }.padding(14).frame(width:340)
                            }.buttonStyle(.plain).background(PassTheme.accent.opacity(0.12),in:RoundedRectangle(cornerRadius:16))
                                .disabled(!account.canContinue).accessibilityIdentifier("calendarContinue" + account.product.displayName)
                        }
                    }
                    Button("Use another account") { useAnotherAccount(); separateAccount = true }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if !store.previewOnly && (accounts.isEmpty || separateAccount) { VStack(spacing:12) {
                    TextField("Proton email or username",text:$username).textFieldStyle(.roundedBorder).accessibilityIdentifier("calendarUsername")
                    SecureField("Password",text:$password).textFieldStyle(.roundedBorder).onSubmit { signIn() }.accessibilityIdentifier("calendarPassword")
                    Button("Sign in to Calendar") { signIn() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(store.busy || username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || password.isEmpty).accessibilityIdentifier("calendarSignIn")
                }.frame(width:340)
                if !accounts.isEmpty { Button("Use an account in ProtonX") { separateAccount = false }.buttonStyle(.plain) }
                Text("Experimental connection · read-only").font(.caption).foregroundStyle(.secondary) }
            }
            if !store.busy && store.phase != .totp && store.phase != .mailboxPassword {
                Button("Explore Calendar preview") { store.enterPreview() }.buttonStyle(.plain).foregroundStyle(PassTheme.accent).accessibilityIdentifier("calendarExplore")
                Text("Sample events only · edits reset on lock or quit").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func signIn() { let value = password; password = ""; store.signIn(username:username,password:value) }
    private func submitChallenge() { let value = challenge; challenge = ""; store.submitChallenge(value) }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { store.beginEvent() } label: { Label("New event", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).disabled(!store.canEdit || store.busy || store.editor != nil).accessibilityIdentifier("calendarNewEvent").help(store.canEdit ? "Create a sample event" : "Event creation will be available after sync validation")
            miniMonth
            Divider()
            Text("My calendars").font(.headline)
            ForEach(store.calendars) { collection in
                Toggle(isOn: Binding(get: { store.visibleCalendarIDs.contains(collection.id) }, set: { _ in store.toggleCalendar(collection.id) })) {
                    Label { Text(collection.name) } icon: { Circle().fill(calendarColors[collection.color]).frame(width: 9, height: 9) }
                }.toggleStyle(.checkbox)
            }
            Spacer()
            Text(store.phase == .connected ? "Proton Calendar" : "Calendar preview").font(.callout.weight(.medium))
            Text(store.phase == .connected ? "Connected · read-only\nEvents stay in memory until lock." : "Sample events only. Proton Calendar is not connected.").font(.caption).foregroundStyle(.secondary)
            if store.phase == .connected {
                HStack { Button("Lock") { store.lock() }; Spacer(); Button("Sign out") { store.signOut() }.disabled(store.busy) }
            }
        }.padding(16).background(PassTheme.sidebar)
    }
    private var miniMonth: some View {
        VStack(spacing: 10) {
            Text(store.date, format: .dateTime.month(.wide).year()).font(.headline)
            HStack { ForEach(["M","T","W","T","F","S","S"].indices, id: \.self) { index in Text(["M","T","W","T","F","S","S"][index]).font(.caption2).frame(maxWidth: .infinity).foregroundStyle(.secondary) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(store.math.month(store.date), id: \.self) { day in
                    let selected = store.math.day(day) == store.math.day(store.date)
                    Button { store.date = day } label: {
                        Text("\(store.math.day(day).day)").font(.caption).frame(maxWidth: .infinity).frame(height: 23)
                            .foregroundStyle(selected ? Color.white : store.math.day(day).month == store.math.day(store.date).month ? Color.primary : Color.secondary)
                            .background(selected ? PassTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: zone)))
                }
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Today") { store.today() }.accessibilityIdentifier("calendarToday")
                Button { store.navigate(-1) } label: { Image(systemName: "chevron.left") }.help("Previous \(store.mode.rawValue.lowercased())")
                Button { store.navigate(1) } label: { Image(systemName: "chevron.right") }.help("Next \(store.mode.rawValue.lowercased())")
                Text(store.date, format: .dateTime.month(.wide).year()).font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Picker("Calendar view", selection: $store.mode) { ForEach(CalendarStore.ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).labelsHidden().frame(width: 100).accessibilityIdentifier("calendarView")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.phase == .connected ? "Search this date range" : "Search events", text: $store.query).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("calendarSearch")
                Spacer()
                Picker("Time zone", selection: $store.timeZoneID) { ForEach(calendarZoneIDs(store.timeZoneID), id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(maxWidth: 210).accessibilityLabel("Calendar time zone")
            }.padding(8).background(PassTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing:8) {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.busy ? "Loading calendars and events…" : store.notice ?? (store.phase == .connected ? "Connected to Proton · read-only" : "Preview · edits stay in memory"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }
    private func inspector(_ event: CalendarEventRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Event").font(.headline); Spacer(); Button { store.selectedEventID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close event") }
                Text(event.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                CalendarEventDateLabel(event: event, math: store.math)
                if case .timed(_,_,let zone) = event.time { Text("Event time zone: \(zone)").font(.caption).foregroundStyle(.secondary) }
                Label(store.calendars.first(where: { $0.id == event.calendarID })?.name ?? "Calendar", systemImage: "calendar")
                if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled) }
                if !event.notes.isEmpty { Text(event.notes).textSelection(.enabled) }
                if event.recurring { Label("Repeating event",systemImage:"repeat").font(.caption).foregroundStyle(.secondary) }
                if store.canEdit { Button("Edit event") { store.beginEvent(event) }.buttonStyle(.borderedProminent).disabled(store.busy).accessibilityIdentifier("calendarEditEvent")
                Button("Delete event", role: .destructive) { deletion = store.deleteIntent() }.disabled(store.busy).accessibilityIdentifier("calendarDeleteEvent") }
                else { Text("Event editing and invitations are coming next.").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("Preview · no event is sent to Proton.").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.background(PassTheme.sidebar)
    }
}

private func calendarZoneIDs(_ selected: String) -> [String] {
    Array(Set([selected,TimeZone.current.identifier,"UTC","Europe/London","Europe/Istanbul","America/New_York","America/Los_Angeles","Asia/Tokyo"])).sorted()
}
@MainActor private func calendarColor(_ event: CalendarEventRecord, store: CalendarStore) -> Color {
    calendarColors[store.calendars.first(where: { $0.id == event.calendarID })?.color ?? 0]
}
private struct CalendarEventDateLabel: View {
    let event: CalendarEventRecord, math: CalendarDateMath
    var body: some View {
        if let (start,end) = math.bounds(event) {
            switch event.time {
            case .timed:
                VStack(alignment: .leading, spacing: 5) {
                    Text(start, format: .dateTime.weekday().day().month().year())
                    Text(start, format: .dateTime.hour().minute()) + Text(" – ") + Text(end, format: math.day(start) == math.day(end) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
                }.font(.callout)
            case .allDay:
                let last = math.addingDays(-1, to: end)
                VStack(alignment: .leading, spacing: 5) {
                    Text(start, format: .dateTime.day().month().year())
                    if math.day(start) != math.day(last) { Text("Through ") + Text(last, format: .dateTime.day().month().year()) }
                    Text("All day").foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
    }
}
private struct CalendarWeekView: View {
    @ObservedObject var store: CalendarStore
    private let hourHeight: CGFloat = 60
    var body: some View {
        let days = store.math.week(store.date)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("\(store.math.calendar.timeZone.abbreviation() ?? "")").font(.caption2).foregroundStyle(.secondary).frame(width: 48)
                ForEach(days, id: \.self) { day in
                    Button { store.date = day } label: {
                        VStack(spacing: 5) { Text(day, format: .dateTime.weekday(.abbreviated)).font(.caption); Text("\(store.math.day(day).day)").font(.title3.weight(.medium)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(store.math.calendar.isDateInToday(day) ? PassTheme.accent : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text("All day").font(.caption2).foregroundStyle(.secondary).frame(width: 48).padding(.top, 5)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 3) { ForEach(store.events(on: day).filter { store.isAllDay($0) }) { event in CalendarEventChip(event: event, store: store) } }
                        .padding(3).frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).font(.caption2).foregroundStyle(.secondary).frame(width: 48, height: hourHeight, alignment: .top).id(hour) }
                        }
                        ForEach(days, id: \.self) { day in dayColumn(day) }
                    }.padding(.top, 5)
                }.onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
    }
    private func dayColumn(_ day: Date) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) { ForEach(0..<24) { _ in Rectangle().fill(Color.secondary.opacity(0.13)).frame(height: 1); Spacer(minLength: 0).frame(height: hourHeight - 1) } }
                Rectangle().fill(Color.secondary.opacity(0.13)).frame(width: 1)
                ForEach(store.math.timedSegments(store.filteredEvents, on: day)) { segment in
                    let width = max(1, (geometry.size.width - 6) / CGFloat(segment.columnCount))
                    Button { store.select(segment.event) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.event.title).font(.caption.weight(.semibold)).lineLimit(2)
                            if segment.endMinute - segment.startMinute >= 40, case .timed(let start,_,_) = segment.event.time {
                                Text(start, format: .dateTime.hour().minute()).font(.caption2).lineLimit(1)
                            }
                        }.padding(5).frame(width: max(1,width - 2), height: max(20,CGFloat(segment.endMinute - segment.startMinute) * hourHeight / 60 - 2), alignment: .topLeading)
                            .background(calendarColor(segment.event, store: store).opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(calendarColor(segment.event, store: store), lineWidth: store.selectedEventID == segment.event.id ? 2 : 0.5))
                    }.buttonStyle(.plain).clipped().offset(x: 3 + CGFloat(segment.column) * width, y: CGFloat(segment.startMinute) * hourHeight / 60)
                        .help(segment.event.title).accessibilityLabel(segment.event.title).accessibilityIdentifier("calendarEvent_" + segment.event.id)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: 24 * hourHeight)
    }
}
private struct CalendarEventChip: View {
    let event: CalendarEventRecord
    @ObservedObject var store: CalendarStore
    var body: some View {
        Button { store.select(event) } label: {
            HStack(spacing: 4) { Circle().fill(calendarColor(event, store: store)).frame(width: 5, height: 5); Text(event.title).font(.caption).lineLimit(1); Spacer(minLength: 0) }
                .padding(4).background(calendarColor(event, store: store).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(event.title).accessibilityIdentifier("calendarEvent_" + event.id)
    }
}
private struct CalendarMonthView: View {
    @ObservedObject var store: CalendarStore
    var body: some View {
        VStack(spacing: 0) {
            HStack { ForEach(["Mon","Tue","Wed","Thu","Fri","Sat","Sun"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }.padding(.vertical, 10)
            GeometryReader { geometry in
                ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(store.math.month(store.date), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { store.date = day } label: { Text("\(store.math.day(day).day)").font(.callout.weight(.medium)).padding(5).background(store.math.day(day) == store.math.day(store.date) ? PassTheme.accent.opacity(0.25) : .clear, in: Circle()) }.buttonStyle(.plain).accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: store.math.calendar.timeZone)))
                            let events = store.events(on: day)
                            ForEach(Array(events.prefix(3))) { event in CalendarEventChip(event: event, store: store) }
                            if events.count > 3 { Button("+\(events.count - 3) more") { store.date = day; store.mode = .agenda }.font(.caption).buttonStyle(.plain) }
                            Spacer(minLength: 0)
                        }.padding(5).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: max(100,geometry.size.height / 6))
                            .opacity(store.math.day(day).month == store.math.day(store.date).month ? 1 : 0.45)
                            .border(Color.secondary.opacity(0.15), width: 0.5)
                    }
                }
                }
            }
        }
    }
}
private struct CalendarAgendaView: View {
    @ObservedObject var store: CalendarStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(0..<14) { offset in
                    let day = store.math.addingDays(offset, to: store.date), events = store.events(on: day)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day, format: .dateTime.weekday(.wide).day().month()).font(.headline)
                        if events.isEmpty { Text("No events").font(.callout).foregroundStyle(.secondary) }
                        ForEach(events) { event in
                            Button { store.select(event) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    RoundedRectangle(cornerRadius: 2).fill(calendarColor(event, store: store)).frame(width: 4)
                                    VStack(alignment: .leading, spacing: 5) { Text(event.title).font(.headline); CalendarEventDateLabel(event: event, math: store.math); if !event.location.isEmpty { Text(event.location).font(.caption).foregroundStyle(.secondary) } }
                                    Spacer()
                                }.padding(12).background(PassTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityIdentifier("calendarEvent_" + event.id)
                        }
                    }
                }
            }.padding(20)
        }
    }
}
private struct CalendarEditorView: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var editor: CalendarEditor
    private var range: ClosedRange<Date> { Date(timeIntervalSince1970: -2208988800)...Date(timeIntervalSince1970: 7258031999) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(editor.expectedRevision == nil ? "New event" : "Edit event").font(.headline); Spacer(); Button { store.cancelEditor() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Cancel event") }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Event title", text: $editor.title).font(.title2).textFieldStyle(.plain).accessibilityIdentifier("calendarEventTitle")
                    Picker("Calendar", selection: $editor.calendarID) { ForEach(store.calendars) { Text($0.name).tag($0.id) } }
                    Toggle("All day", isOn: Binding(get: { editor.allDay }, set: { editor.changeAllDay($0) })).accessibilityIdentifier("calendarAllDay")
                    DatePicker("Starts", selection: $editor.start, in: range, displayedComponents: editor.allDay ? [.date] : [.date,.hourAndMinute]).accessibilityIdentifier("calendarEventStart")
                    DatePicker("Ends", selection: $editor.end, in: range, displayedComponents: editor.allDay ? [.date] : [.date,.hourAndMinute]).accessibilityIdentifier("calendarEventEnd")
                    if editor.allDay { Text("The last day is included.").font(.caption).foregroundStyle(.secondary) }
                    else { Picker("Time zone", selection: $editor.timeZoneID) { ForEach(calendarZoneIDs(editor.timeZoneID), id: \.self) { Text($0).tag($0) } } }
                    TextField("Location", text: $editor.location).textFieldStyle(.roundedBorder).accessibilityIdentifier("calendarEventLocation")
                    Text("Notes").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $editor.notes).frame(minHeight: 140).padding(5).background(PassTheme.canvas, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("calendarEventNotes")
                    Text("Preview · edits stay in memory. No invitations or reminders are sent.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.environment(\.timeZone, TimeZone(identifier: editor.timeZoneID) ?? .gmt)
            Divider()
            HStack { Button("Cancel") { store.cancelEditor() }; Spacer(); Button("Save event") { store.saveEditor() }.buttonStyle(.borderedProminent).accessibilityIdentifier("calendarSaveEvent") }.padding(16)
        }.disabled(store.busy).background(PassTheme.sidebar)
    }
}
