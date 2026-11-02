import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

@main
struct PokoApp: App {
    @StateObject private var session = PokoSession()

    init() {
        if FirebaseApp.app() == nil {
            if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
                FirebaseApp.configure()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(session.colorScheme)
                .tint(PokoStyle.accent)
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
        }
    }
}

enum PokoStyle {
    static let accent = Color(red: 0.48, green: 0.61, blue: 0.96)
    static let background = Color(uiColor: .systemBackground)
    static let panel = Color(uiColor: .secondarySystemBackground)
    static let muted = Color.secondary
}

@MainActor
final class PokoSession: ObservableObject {
    @Published var user: User?
    @Published var profile: PokoProfile?
    @Published var conversations: [PokoConversation] = []
    @Published var friends: [PokoProfile] = []
    @Published var incomingRequests: [PokoFriendRequest] = []
    @Published var error: String?
    @Published var theme = UserDefaults.standard.string(forKey: "poko-theme") ?? "system"
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var conversationListener: ListenerRegistration?
    private var friendListener: ListenerRegistration?
    private var requestListener: ListenerRegistration?

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                if let user { self?.start(user: user) }
                else { self?.stop(); self?.profile = nil }
            }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
        conversationListener?.remove(); friendListener?.remove(); requestListener?.remove()
    }

    var colorScheme: ColorScheme? {
        theme == "dark" ? .dark : theme == "light" ? .light : nil
    }

    func setTheme(_ value: String) {
        theme = value
        UserDefaults.standard.set(value, forKey: "poko-theme")
    }

    private func stop() {
        conversationListener?.remove(); friendListener?.remove(); requestListener?.remove()
        conversationListener = nil; friendListener = nil; requestListener = nil
        conversations = []; friends = []; incomingRequests = []
    }

    private func start(user: User) {
        guard let db = try? database else { error = "Firebase is not configured. Add your iOS GoogleService-Info.plist."; return }
        db.collection("profiles").document(user.uid).addSnapshotListener { [weak self] snap, _ in
            guard let data = snap?.data() else { return }
            Task { @MainActor in self?.profile = PokoProfile(uid: user.uid, data: data) }
        }
        conversationListener = db.collection("conversations").whereField("participants", arrayContains: user.uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                Task { @MainActor in
                    self?.conversations = docs.map { PokoConversation(id: $0.documentID, data: $0.data(), currentUID: user.uid) }
                        .sorted { ($0.updatedAt?.dateValue() ?? .distantPast) > ($1.updatedAt?.dateValue() ?? .distantPast) }
                }
            }
        friendListener = db.collection("friendships").whereField("users", arrayContains: user.uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                Task { @MainActor in
                    let ids = docs.compactMap { ($0.data()["users"] as? [String])?.first { $0 != user.uid } }
                    self?.loadProfiles(ids)
                }
            }
        requestListener = db.collection("friendRequests").whereField("toUid", isEqualTo: user.uid)
            .whereField("status", isEqualTo: "pending").addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor in self?.incomingRequests = snapshot?.documents.map { PokoFriendRequest(id: $0.documentID, data: $0.data()) } ?? [] }
            }
    }

    private func loadProfiles(_ ids: [String]) {
        guard !ids.isEmpty, let db = try? database else { friends = []; return }
        Task {
            var loaded: [PokoProfile] = []
            for id in ids {
                if let doc = try? await db.collection("profiles").document(id).getDocument(), let data = doc.data() {
                    loaded.append(PokoProfile(uid: id, data: data))
                }
            }
            friends = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var database: Firestore {
        get throws {
            guard FirebaseApp.app() != nil else { throw PokoError.firebaseMissing }
            return Firestore.firestore()
        }
    }

    func signInGoogle() async {
        guard let clientID = FirebaseApp.app()?.options.clientID,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            error = "Add a valid GoogleService-Info.plist for the iOS app in Firebase Console."
            return
        }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller, hint: nil, additionalScopes: [])
            guard let idToken = result.user.idToken?.tokenString else { throw PokoError.googleToken }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            _ = try await Auth.auth().signIn(with: credential)
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        do { try Auth.auth().signOut(); GIDSignIn.sharedInstance.signOut() }
        catch { error = error.localizedDescription }
    }

    func createConversation(with profile: PokoProfile) async throws -> String {
        guard let user, let db = try? database else { throw PokoError.firebaseMissing }
        let participants = [user.uid, profile.uid].sorted()
        let existing = try await db.collection("conversations").whereField("participants", arrayContains: user.uid).getDocuments()
        if let match = existing.documents.first(where: { ($0.data()["participants"] as? [String])?.sorted() == participants }) { return match.documentID }
        let ref = db.collection("conversations").document()
        try await ref.setData(["participants": participants, "type": "direct", "createdAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp()])
        return ref.documentID
    }

    func createGroup(name: String, members: [PokoProfile]) async throws {
        guard let user, let db = try? database else { throw PokoError.firebaseMissing }
        let ids = Array(Set([user.uid] + members.map(\.uid))).sorted()
        guard ids.count > 2 else { throw PokoError.invalidGroup }
        try await db.collection("conversations").addDocument(data: ["participants": ids, "type": "group", "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "createdAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp()])
    }

    func searchUsers(_ query: String) async throws -> [PokoProfile] {
        guard let user, let db = try? database else { throw PokoError.firebaseMissing }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let result = try await db.collection("profiles").whereField("name", isEqualTo: value).limit(to: 20).getDocuments()
        return result.documents.filter { $0.documentID != user.uid }.map { PokoProfile(uid: $0.documentID, data: $0.data()) }
    }

    func sendFriendRequest(_ profile: PokoProfile) async throws {
        guard let user, let db = try? database else { throw PokoError.firebaseMissing }
        let key = [user.uid, profile.uid].sorted().joined(separator: "_")
        let friendship = try await db.collection("friendships").document(key).getDocument()
        if friendship.exists { return }
        let pending = try await db.collection("friendRequests").whereField("fromUid", isEqualTo: user.uid).whereField("toUid", isEqualTo: profile.uid).whereField("status", isEqualTo: "pending").limit(to: 1).getDocuments()
        if !pending.isEmpty { return }
        try await db.collection("friendRequests").addDocument(data: ["fromUid": user.uid, "toUid": profile.uid, "status": "pending", "createdAt": FieldValue.serverTimestamp()])
    }

    func respond(_ request: PokoFriendRequest, accept: Bool) async throws {
        guard let db = try? database else { throw PokoError.firebaseMissing }
        let ref = db.collection("friendRequests").document(request.id)
        if accept {
            guard let from = request.fromUID, let to = user?.uid else { return }
            let key = [from, to].sorted().joined(separator: "_")
            let batch = db.batch()
            batch.setData(["users": [from, to].sorted(), "createdAt": FieldValue.serverTimestamp()], forDocument: db.collection("friendships").document(key))
            batch.updateData(["status": "accepted", "updatedAt": FieldValue.serverTimestamp()], forDocument: ref)
            try await batch.commit()
        } else {
            try await ref.updateData(["status": "declined", "updatedAt": FieldValue.serverTimestamp()])
        }
    }

    func updateProfile(name: String, bio: String) async throws {
        guard let user, let db = try? database else { throw PokoError.firebaseMissing }
        try await db.collection("profiles").document(user.uid).setData(["name": name, "bio": bio, "updatedAt": FieldValue.serverTimestamp()], merge: true)
    }
}

enum PokoError: LocalizedError {
    case firebaseMissing, googleToken, invalidGroup
    var errorDescription: String? {
        switch self {
        case .firebaseMissing: "Firebase is not configured. Add GoogleService-Info.plist."
        case .googleToken: "Google did not return an ID token."
        case .invalidGroup: "A group chat needs at least two other members."
        }
    }
}

struct PokoProfile: Identifiable, Hashable {
    let uid: String
    let name: String
    let bio: String
    let avatar: String
    let status: String
    var id: String { uid }
    init(uid: String, data: [String: Any]) {
        self.uid = uid; name = data["name"] as? String ?? "Poko user"
        bio = data["bio"] as? String ?? ""; avatar = data["avatar"] as? String ?? ""
        status = data["status"] as? String ?? "offline"
    }
}

struct PokoConversation: Identifiable {
    let id: String
    let name: String
    let isGroup: Bool
    let lastMessage: String
    let updatedAt: Timestamp?
    let otherUID: String?
    init(id: String, data: [String: Any], currentUID: String) {
        self.id = id; let ids = data["participants"] as? [String] ?? []
        otherUID = ids.first { $0 != currentUID }; isGroup = (data["type"] as? String == "group") || ids.count > 2
        name = data["name"] as? String ?? (isGroup ? "Group chat" : "Conversation")
        lastMessage = data["lastMessage"] as? String ?? "Start a conversation"
        updatedAt = data["updatedAt"] as? Timestamp
    }
}

struct PokoFriendRequest: Identifiable {
    let id: String
    let fromUID: String?
    init(id: String, data: [String: Any]) { self.id = id; fromUID = data["fromUid"] as? String }
}

struct PokoMessage: Identifiable {
    let id: String
    let text: String
    let senderID: String
    let timestamp: Timestamp?
    init(_ doc: QueryDocumentSnapshot) {
        let data = doc.data(); id = doc.documentID; text = data["text"] as? String ?? (data["gifUrl"] as? String ?? "Attachment")
        senderID = data["senderId"] as? String ?? ""; timestamp = data["createdAt"] as? Timestamp
    }
}
