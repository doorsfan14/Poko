import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import PhotosUI

struct RootView: View {
    @EnvironmentObject private var session: PokoSession
    var body: some View {
        Group {
            if session.user == nil { SignInView() } else { MainTabView() }
        }
        .alert("Poko", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}

struct SignInView: View {
    @EnvironmentObject private var session: PokoSession
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 54)).foregroundStyle(PokoStyle.accent)
            Text("Poko").font(.system(size: 36, weight: .bold, design: .rounded))
            Text("Find your people and keep your conversations together.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: { Task { await session.signInGoogle() } }) {
                Label("Continue with Google", systemImage: "g.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding()
                    .background(PokoStyle.accent, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
            }
            Text("Sign in securely with your Google account.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }.padding(28)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { ConversationListView() }
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
            NavigationStack { FriendsView() }
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
            NavigationStack { ProfileView() }
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
        }
    }
}

struct ConversationListView: View {
    @EnvironmentObject private var session: PokoSession
    @State private var query = ""
    @State private var showNew = false
    @State private var showGroup = false
    var filtered: [PokoConversation] {
        session.conversations.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.lastMessage.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            ForEach(filtered) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            Circle().fill(PokoStyle.accent.opacity(0.2)).frame(width: 48, height: 48)
                                .overlay(Image(systemName: item.isGroup ? "person.3.fill" : "person.fill").foregroundStyle(PokoStyle.accent))
                            Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(.background,lineWidth: 2)).offset(x: 1,y: 1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            Text(item.lastMessage).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Messages")
        .searchable(text: $query, prompt: "Search messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New message", systemImage: "square.and.pencil") { showNew = true }
                    Button("Create group", systemImage: "person.3") { showGroup = true }
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .navigationDestination(for: PokoConversation.self) { ConversationView(conversation: $0) }
        .sheet(isPresented: $showNew) { NewConversationView() }
        .sheet(isPresented: $showGroup) { GroupConversationView() }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a new message to find someone on Poko."))
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var session: PokoSession
    let conversation: PokoConversation
    @State private var messages: [PokoMessage] = []
    @State private var draft = ""
    @State private var listener: ListenerRegistration?
    @FocusState private var focused: Bool
    private var db: Firestore { Firestore.firestore() }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { message in
                            HStack {
                                if message.senderID == session.user?.uid { Spacer(minLength: 44) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.senderID == session.user?.uid ? "You" : conversation.name)
                                        .font(.caption.bold()).foregroundStyle(PokoStyle.accent)
                                    Text(message.text).textSelection(.enabled)
                                }
                                .padding(12).background(message.senderID == session.user?.uid ? PokoStyle.accent.opacity(0.2) : PokoStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                                if message.senderID != session.user?.uid { Spacer(minLength: 44) }
                            }.id(message.id)
                        }
                    }.padding()
                }
                .onChange(of: messages.count) { _, _ in if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            HStack(spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).focused($focused)
                    .padding(12).background(PokoStyle.panel, in: RoundedRectangle(cornerRadius: 20))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(conversation.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { listen() }.onDisappear { listener?.remove() }
    }

    private func listen() {
        listener = db.collection("conversations").document(conversation.id).collection("messages")
            .order(by: "createdAt").addSnapshotListener { snap, _ in
                messages = snap?.documents.map(PokoMessage.init) ?? []
            }
    }
    private func send() {
        guard let user = session.user else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let ref = db.collection("conversations").document(conversation.id)
        ref.collection("messages").addDocument(data: ["text": text, "senderId": user.uid, "createdAt": FieldValue.serverTimestamp()])
        ref.updateData(["lastMessage": String(text.prefix(180)), "lastSenderId": user.uid, "updatedAt": FieldValue.serverTimestamp()])
    }
}

struct NewConversationView: View {
    @EnvironmentObject private var session: PokoSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PokoProfile] = []
    @State private var loading = false
    var body: some View {
        NavigationStack {
            List(results) { profile in
                Button {
                    Task {
                        do {
                            let id = try await session.createConversation(with: profile)
                            NotificationCenter.default.post(name: .pokoOpenConversation, object: id)
                            dismiss()
                        } catch { session.error = error.localizedDescription }
                    }
                } label: { ProfileRow(profile: profile) }.tint(.primary)
            }
            .searchable(text: $query, prompt: "Enter an exact username")
            .onChange(of: query) { _, value in
                Task { loading = true; defer { loading = false }; do { results = try await session.searchUsers(value) } catch { session.error = error.localizedDescription } }
            }
            .navigationTitle("New message").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .overlay { if results.isEmpty { ContentUnavailableView("Find someone", systemImage: "person.crop.circle.badge.plus", description: Text("Search by their exact Poko display name.")) } }
        }
    }
}

struct GroupConversationView: View {
    @EnvironmentObject private var session: PokoSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var results: [PokoProfile] = []
    @State private var selected: Set<String> = []
    var body: some View {
        NavigationStack {
            List {
                Section("Group details") { TextField("Group name", text: $name) }
                Section("Add people") {
                    TextField("Search exact username", text: $query)
                        .onChange(of: query) { _, value in Task { results = (try? await session.searchUsers(value)) ?? [] } }
                    ForEach(results) { profile in
                        Button { if selected.contains(profile.uid) { selected.remove(profile.uid) } else { selected.insert(profile.uid) } } label: {
                            HStack { ProfileRow(profile: profile); Spacer(); Image(systemName: selected.contains(profile.uid) ? "checkmark.circle.fill" : "circle") }
                        }.tint(.primary)
                    }
                }
            }.navigationTitle("New group")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Create") {
                            Task {
                                do {
                                    try await session.createGroup(name: name, members: results.filter { selected.contains($0.uid) })
                                    dismiss()
                                } catch { session.error = error.localizedDescription }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.count < 2)
                    }
                }
        }
    }
}

struct FriendsView: View {
    @EnvironmentObject private var session: PokoSession
    @State private var query = ""
    @State private var results: [PokoProfile] = []
    var body: some View {
        List {
            if !session.incomingRequests.isEmpty {
                Section("Pending requests") {
                    ForEach(session.incomingRequests) { request in
                        HStack {
                            Text("Friend request")
                            Spacer()
                            Button("Accept") { Task { try? await session.respond(request, accept: true) } }
                            Button("Decline") { Task { try? await session.respond(request, accept: false) } }.tint(.secondary)
                        }
                    }
                }
            }
            Section("All friends") {
                ForEach(session.friends) { profile in ProfileRow(profile: profile) }
            }
            Section("Find people") {
                TextField("Search exact username", text: $query)
                    .onChange(of: query) { _, value in Task { results = (try? await session.searchUsers(value)) ?? [] } }
                ForEach(results) { profile in
                    HStack { ProfileRow(profile: profile); Spacer(); Button("Add") { Task { try? await session.sendFriendRequest(profile) } } }
                }
            }
        }.navigationTitle("Friends")
    }
}

struct ProfileRow: View {
    let profile: PokoProfile
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: profile.avatar)) { image in image.resizable().scaledToFill() } placeholder: {
                Circle().fill(PokoStyle.accent.opacity(0.2)).overlay(Text(String(profile.name.prefix(1))).font(.headline))
            }.frame(width: 42, height: 42).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text(profile.bio.isEmpty ? profile.status.capitalized : profile.bio).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var session: PokoSession
    @State private var name = ""
    @State private var bio = ""
    @State private var editing = false
    var body: some View {
        Form {
            Section("Account") {
                HStack { Text(session.user?.displayName ?? session.profile?.name ?? "Poko user"); Spacer(); Text("Google").foregroundStyle(.secondary) }
                Text(session.user?.email ?? "")
                Button("Log out", role: .destructive) { session.signOut() }
            }
            Section("Profile") {
                TextField("Display name", text: $name)
                TextField("About me", text: $bio, axis: .vertical)
                Button("Save profile") { Task { do { try await session.updateProfile(name: name, bio: bio) } catch { session.error = error.localizedDescription } } }
            }
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { session.theme }, set: session.setTheme)) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("About") { LabeledContent("Poko for iOS", value: "Native SwiftUI") }
        }.navigationTitle("You")
            .onAppear { name = session.profile?.name ?? session.user?.displayName ?? ""; bio = session.profile?.bio ?? "" }
    }
}

extension Notification.Name {
    static let pokoOpenConversation = Notification.Name("pokoOpenConversation")
}
