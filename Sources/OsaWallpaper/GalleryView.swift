import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage

// Fenêtre « Fonds d'écran » : une grande base de photos HD, les vidéos aériennes d'Apple,
// un lien (YouTube, .mp4) ou un fichier du Mac. Aperçu à droite, sur une maquette de l'écran verrouillé.

enum GalleryTab: String, CaseIterable, Identifiable {
    case photos = "Photos", aerials = "Vidéos Apple", link = "Ton lien", mine = "Mes fonds"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .aerials: "airplane"
        case .link: "link"
        case .mine: "heart.fill"
        }
    }
}

@MainActor
final class GalleryModel: ObservableObject {
    @Published var tab: GalleryTab = GalleryTab.allCases.first { $0.rawValue == ProcessInfo.processInfo.environment["OSAWALLPAPER_GALLERY"] } ?? .photos
    @Published var selected: Wallpaper?

    // Photos (Wallhaven)
    @Published var topic = 0
    @Published var query = ProcessInfo.processInfo.environment["OSAWALLPAPER_QUERY"] ?? ""
    @Published private(set) var photos: [Wallhaven.Item] = []
    @Published private(set) var loadingPhotos = false
    @Published private(set) var photoError: String?
    private var page = 0, lastPage = 1, gen = 0

    // Vidéos aériennes
    @Published private(set) var aerials: AppleAerials.Catalog?
    @Published var aerialCategory: String?
    @Published private(set) var aerialError: String?

    private var searchQuery: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? Wallhaven.topics[topic].q : PhotoNames.english(q)
    }

    func loadPhotos(reset: Bool) {
        if reset { gen += 1; page = 0; lastPage = 1; photos = []; loadingPhotos = false; photoError = nil }
        guard !loadingPhotos, page < lastPage else { return }
        loadingPhotos = true
        let g = gen, next = page + 1, q = searchQuery
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                var r = try await Wallhaven.search(q, page: next)
                // Rien trouvé avec un mot inconnu ? On réessaie avec les seuls mots compris.
                if r.data.isEmpty, next == 1, !typed.isEmpty {
                    let k = PhotoNames.english(typed, knownOnly: true)
                    if !k.isEmpty, k != q { r = try await Wallhaven.search(k, page: next) }
                }
                guard g == gen else { return }
                page = next; lastPage = r.meta.last_page
                let seen = Set(photos.map(\.id))
                photos += r.data.filter { !seen.contains($0.id) }
                if Demo.on, selected == nil, let i = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO_SELECT"].flatMap(Int.init), i < photos.count {
                    selected = photos[i].wallpaper(PhotoNames.shared.names[photos[i].id])
                }
            } catch {
                if g == gen { photoError = "Impossible de charger les photos. Vérifie ta connexion, puis réessaie." }
            }
            if g == gen { loadingPhotos = false }
        }
    }

    func loadAerials() {
        guard aerials == nil else { return }
        aerialError = nil
        Task {
            do { aerials = try await AppleAerials.load() }
            catch { aerialError = "Le catalogue d’Apple ne répond pas. Réessaie dans un instant." }
        }
    }
}

struct GalleryView: View {
    @StateObject private var model = GalleryModel()
    @ObservedObject var store: WallpaperStore
    @ObservedObject var prefs: Prefs
    @ObservedObject private var names = PhotoNames.shared
    var onPreview: () -> Void
    @Namespace private var tabNS

    private var shown: Wallpaper? { (model.selected ?? store.current).map(named) }

    /// Une photo Wallhaven prend son nom dès qu'il est connu.
    private func named(_ w: Wallpaper) -> Wallpaper {
        guard w.id.hasPrefix("wh-"), let n = names.names[String(w.id.dropFirst(3))] else { return w }
        var r = w; r.title = n.title; r.subtitle = n.credit ?? w.subtitle
        return r
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06)      // fond fixe, ne suit pas la photo choisie
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PreviewPane(item: shown, tags: shown.flatMap { names.names[String($0.id.dropFirst(3))]?.tags } ?? [],
                            store: store, prefs: prefs, onPreview: onPreview)
                    .frame(width: 320)
                    .background(.black.opacity(0.28))
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            if model.photos.isEmpty { model.loadPhotos(reset: true) }
            store.unnamedPhotos.forEach { names.want($0, urgent: true) }
            store.applyNames(names.names)
        }
        .onChange(of: names.names) { store.applyNames(names.names) }
    }

    // MARK: En-tête + onglets

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fonds d’écran").font(.system(size: 19, weight: .bold))
                Text("Pour ton écran verrouillé et ton bureau").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 16)
            HStack(spacing: 2) {
                ForEach(GalleryTab.allCases) { t in
                    Button { withAnimation(.spring(duration: 0.3)) { model.tab = t } } label: {
                        Label(t.rawValue, systemImage: t.icon)
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .foregroundStyle(model.tab == t ? .black : .white.opacity(0.7))
                            .background {
                                if model.tab == t { Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: tabNS) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        }
        .padding(.leading, 22).padding(.trailing, 18)
        .padding(.top, 34).padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .photos: photosTab
        case .aerials: aerialsTab
        case .link: LinkTab(store: store, select: { model.selected = $0 })
        case .mine: mineTab
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 186), spacing: 12)]

    private func grid<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) { c() }
                .padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func card(_ w: Wallpaper, naming: Bool = false) -> some View {
        WallCard(w: w, selected: model.selected?.id == w.id, current: store.current?.id == w.id,
                 progress: store.progress[w.id], naming: naming)
            .onTapGesture(count: 2) { select(w); store.apply(named(w)) }
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { select(w) } }
    }

    private func select(_ w: Wallpaper) {
        model.selected = w
        if w.id.hasPrefix("wh-") { names.want(String(w.id.dropFirst(3)), urgent: true) }
    }

    // MARK: Photos

    private var photosTab: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("", text: $model.query, prompt: Text("Rechercher : montagne, plage, Tokyo, aurore boréale…").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .onSubmit { model.loadPhotos(reset: true) }
                if !model.query.isEmpty {
                    Button { model.query = ""; model.loadPhotos(reset: true) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
            .padding(.horizontal, 22)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(Wallhaven.topics.enumerated()), id: \.offset) { i, t in
                        Chip(label: t.label, icon: t.icon, on: model.query.isEmpty && model.topic == i) {
                            model.query = ""; model.topic = i; model.loadPhotos(reset: true)
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))

            if let e = model.photoError, model.photos.isEmpty {
                ErrorState(text: e) { model.loadPhotos(reset: true) }
            } else if model.photos.isEmpty && !model.loadingPhotos {
                Empty(icon: "photo", text: "Aucune photo pour cette recherche.")
            } else {
                grid {
                    ForEach(model.photos) { p in
                        let n = names.names[p.id]
                        card(p.wallpaper(n), naming: n == nil)
                            .onAppear {
                                names.want(p.id)
                                if p.id == model.photos.last?.id { model.loadPhotos(reset: false) }
                            }
                            .onDisappear { names.forget(p.id) }
                    }
                    if model.loadingPhotos {
                        ForEach(0..<(model.photos.isEmpty ? 12 : 4), id: \.self) { _ in SkeletonCard() }
                    }
                }
            }
            Text("Photos de la communauté Wallhaven, filtrées « tout public », 1440p minimum. Les noms viennent de leurs mots-clés.")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3)).padding(.bottom, 10)
        }
    }

    // MARK: Vidéos Apple

    private var aerialsTab: some View {
        VStack(spacing: 12) {
            if let c = model.aerials {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Chip(label: "Toutes", icon: "sparkles.tv", on: model.aerialCategory == nil) { model.aerialCategory = nil }
                        ForEach(c.categories, id: \.id) { cat in
                            Chip(label: cat.name, icon: Self.aerialIcon(cat.name), on: model.aerialCategory == cat.id) { model.aerialCategory = cat.id }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.never)
                grid {
                    ForEach(c.items.filter { model.aerialCategory == nil || $0.categories.contains(model.aerialCategory!) }) { a in
                        card(a.wallpaper)
                    }
                }
                Text("Les vidéos aériennes de l’Apple TV et de l’économiseur d’écran, en 1080p.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3)).padding(.bottom, 10)
            } else if let e = model.aerialError {
                ErrorState(text: e) { model.loadAerials() }
            } else {
                grid { ForEach(0..<12, id: \.self) { _ in SkeletonCard() } }
            }
        }
        .onAppear { model.loadAerials() }
    }

    static func aerialIcon(_ name: String) -> String {
        switch name {
        case "Terre", "Earth": "globe.europe.africa.fill"
        case "Sous l’eau", "Underwater": "fish.fill"
        case "Paysage urbain", "Cityscape": "building.2.fill"
        default: "mountain.2.fill"
        }
    }

    // MARK: Mes fonds

    @ViewBuilder private var mineTab: some View {
        if store.history.isEmpty {
            Empty(icon: "heart", text: "Les fonds que tu utilises s’affichent ici.")
        } else {
            VStack(spacing: 10) {
                HStack {
                    Text("\(store.history.count) fond\(store.history.count > 1 ? "s" : "")").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    if store.current != nil {
                        Button { store.clear(); model.selected = nil } label: {
                            Label("Revenir à la pochette seule", systemImage: "music.note").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 22)
                grid {
                    ForEach(store.history) { w in
                        card(w)
                            .contextMenu {
                                Button("Utiliser") { store.apply(w) }
                                Button("Supprimer", role: .destructive) {
                                    if model.selected?.id == w.id { model.selected = nil }
                                    store.remove(w)
                                }
                            }
                    }
                }
            }
        }
    }
}

func fallbackThumb(_ w: Wallpaper?) -> URL? {
    // Toutes les vidéos YouTube n'ont pas de miniature « maxres ».
    w?.youtubeID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
}

// MARK: - Panneau d'aperçu

struct PreviewPane: View {
    let item: Wallpaper?
    var tags: [String] = []
    @ObservedObject var store: WallpaperStore
    @ObservedObject var prefs: Prefs
    var onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("APERÇU").font(.system(size: 10.5, weight: .bold)).tracking(1.6).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("v\(Updater.current)").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.top, 38)
            LockMock(item: item)
            if let w = item {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(w.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        if let b = w.badge { Badge(text: b) }
                    }
                    if let s = w.subtitle { Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(3) }
                    if !tags.isEmpty {
                        FlowTags(tags: tags).padding(.top, 4)
                    }
                    Text(Self.note(w)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.38)).padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                action(w)
            } else {
                Text("Choisis une photo ou une vidéo : elle remplace le fond de ton écran verrouillé.")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DesktopOptions(prefs: prefs, kind: store.current?.kind)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Quand de la musique joue").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Picker("", selection: $prefs.wallpaperOverMusic) {
                    Text("Pochette de l’album").tag(false)
                    Text("Garder mon fond").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                Button(action: onPreview) {
                    Label("Voir sur l’écran (8 s)", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButton()).disabled(store.current == nil).opacity(store.current == nil ? 0.4 : 1)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private func action(_ w: Wallpaper) -> some View {
        if let p = store.progress[w.id] {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p).tint(.white)
                HStack {
                    Text("Téléchargement… \(Int(p * 100)) %").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button("Annuler") { store.cancel(w.id) }.buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
                }
            }
        } else if store.current?.id == w.id {
            HStack {
                Label("Sur ton écran verrouillé", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                Spacer()
                Button("Retirer") { store.clear() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(height: 38)
        } else {
            Button { store.apply(w) } label: {
                Label("Utiliser sur l’écran verrouillé", systemImage: "lock.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
        }
    }

    static func note(_ w: Wallpaper) -> String {
        switch w.kind {
        case .youtube: "Lue en direct depuis YouTube, sans le son, seulement quand on peut la voir. Il faut une connexion internet."
        case .video where w.id.hasPrefix("aerial-"): "Vidéo 1080p lue en boucle, sans le son. Téléchargée une seule fois (150 à 300 Mo)."
        case .video: "Lue en boucle, sans le son, seulement quand on peut la voir."
        case .image: w.local == nil && w.remote != nil ? "Téléchargée une fois en pleine qualité." : "Photo enregistrée sur ton Mac."
        }
    }
}

/// « Aussi sur le bureau » et, pour une vidéo, animée ou image fixe.
struct DesktopOptions: View {
    @ObservedObject var prefs: Prefs
    let kind: Wallpaper.Kind?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $prefs.desktopToo) {
                HStack(spacing: 10) {
                    Image(systemName: "menubar.dock.rectangle").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Aussi sur le bureau").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        Text(kind == nil ? "Choisis d’abord un fond" : "Le même fond quand ton Mac est déverrouillé")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .toggleStyle(.switch).disabled(kind == nil)
            if prefs.desktopToo, let kind, kind != .image {
                Picker("", selection: $prefs.desktopAnimated) {
                    Text("Animé").tag(true)
                    Text("Image fixe").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(prefs.desktopAnimated
                     ? "La vidéo tourne derrière tes fenêtres, en pause quand ton Mac est verrouillé, en veille ou en économie d’énergie."
                     : "Une image tirée de la vidéo : aucun effort pour ton Mac.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .opacity(kind == nil ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: prefs.desktopToo)
    }
}

/// Maquette de l'écran verrouillé : le fond, la date, l'heure et le champ du mot de passe.
struct LockMock: View {
    let item: Wallpaper?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Color.black
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let item {
                    Thumb(url: item.thumb, fallback: fallbackThumb(item)).id(item.id).transition(.opacity)
                } else {
                    LinearGradient(colors: [Color(red: 0.24, green: 0.16, blue: 0.4), Color(red: 0.06, green: 0.06, blue: 0.12)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
            .overlay {
                TimelineView(.everyMinute) { tl in
                    VStack(spacing: 0) {
                        Text(tl.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized(with: Locale(identifier: "fr_FR")))
                            .font(.system(size: 9, weight: .semibold)).opacity(0.85)
                        Text(tl.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                            .font(.system(size: 42, weight: .bold)).kerning(-1).opacity(0.92).fixedSize()
                        Spacer()
                        Capsule().fill(.white.opacity(0.22)).frame(width: 70, height: 12)
                            .overlay(Text("Mot de passe").font(.system(size: 5.5)).opacity(0.6))
                            .padding(.bottom, 14)
                    }
                    .padding(.top, 12)
                    .shadow(color: .black.opacity(0.25), radius: 6)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .animation(.easeInOut(duration: 0.35), value: item?.id)
    }
}

// MARK: - Onglet « Ton lien »

struct LinkTab: View {
    @ObservedObject var store: WallpaperStore
    var select: (Wallpaper) -> Void
    @State private var text = ""
    @State private var invalid = false
    @State private var dropping = false
    @State private var checking = false
    @State private var unavailable = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Colle un lien", systemImage: "link").font(.system(size: 15, weight: .bold))
                    Text("Une vidéo YouTube, ou un lien direct vers une vidéo (.mp4, .mov) ou une image (.jpg, .png, .heic).")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 8) {
                        TextField("", text: $text, prompt: Text("https://www.youtube.com/watch?v=…").foregroundStyle(.white.opacity(0.3)))
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(invalid ? .orange.opacity(0.7) : .white.opacity(0.08)))
                            .onSubmit(validate)
                            .onChange(of: text) { invalid = false; unavailable = false }
                        Button(action: validate) {
                            if checking { ProgressView().controlSize(.small).tint(.black) } else { Text("Valider") }
                        }
                        .buttonStyle(PrimaryButton(compact: true)).disabled(text.isEmpty || checking)
                    }
                    if invalid {
                        Text("Ce lien n’est ni une vidéo YouTube, ni un fichier vidéo ou image direct.")
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                    if unavailable {
                        Text("Cette vidéo YouTube est introuvable, privée, ou son auteur interdit de l’afficher ailleurs que sur YouTube.")
                            .font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Badge(text: "YouTube"); Badge(text: ".mp4 · .mov"); Badge(text: ".jpg · .png · .heic")
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))

                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(dropping ? 0.9 : 0.5))
                    Text("Glisse une image ou une vidéo ici").font(.system(size: 14, weight: .semibold))
                    Text("Elle est copiée dans OsaWallpaper : tu peux ensuite déplacer l’original.")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                    Button("Choisir sur mon Mac…", action: pick).buttonStyle(GlassButton()).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(dropping ? 0.1 : 0.03)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(dropping ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { importAndSelect(url) } }
                    }
                    return true
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 22)
        }
        .scrollIndicators(.never)
    }

    private func validate() {
        guard let w = WallpaperStore.fromLink(text) else { invalid = true; return }
        guard w.kind == .youtube else { select(w); return }
        checking = true
        Task { @MainActor in
            let info = await WallpaperStore.youtubeInfo(w)
            checking = false
            if let info { select(info) } else { unavailable = true }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .movie]
        p.allowsMultipleSelection = false
        p.message = "Choisis une image ou une vidéo pour ton écran verrouillé"
        p.prompt = "Utiliser"
        if p.runModal() == .OK, let u = p.url { importAndSelect(u) }
    }

    private func importAndSelect(_ u: URL) {
        store.importFile(u)
        if let c = store.current, store.error == nil { select(c) }
    }
}

// MARK: - Petits éléments

struct WallCard: View {
    let w: Wallpaper
    let selected: Bool
    let current: Bool
    let progress: Double?
    var naming = false            // nom pas encore connu : petite barre animée à la place
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Color.black
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(Thumb(url: w.thumb, fallback: fallbackThumb(w)))
            .overlay(alignment: .bottomLeading) {
                Group {
                    VStack(alignment: .leading, spacing: 1) {
                        if naming {
                            SkeletonLine(width: 110).padding(.vertical, 3)
                        } else {
                            Text(w.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        if let s = w.subtitle { Text(s).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8).padding(.top, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let b = w.badge { Badge(text: b, dark: true).padding(7) }
            }
            .overlay(alignment: .topLeading) {
                if current {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green).padding(7).shadow(radius: 3)
                }
            }
            .overlay {
                if let p = progress {
                    ZStack {
                        Color.black.opacity(0.5)
                        ZStack {
                            Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                            Circle().trim(from: 0, to: max(0.02, p)).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 34, height: 34)
                        .animation(.linear(duration: 0.2), value: p)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? .white : .white.opacity(hover ? 0.28 : 0.08), lineWidth: selected ? 2.5 : 1))
            .scaleEffect(hover ? 1.025 : 1)
            .shadow(color: .black.opacity(hover ? 0.45 : 0.2), radius: hover ? 14 : 6, y: hover ? 8 : 3)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.spring(duration: 0.28), value: hover)
            .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// Miniature distante ou locale, avec une seconde adresse si la première échoue.
struct Thumb: View {
    let url: URL?
    var fallback: URL? = nil
    var body: some View {
        // Color.clear donne la taille ; l'image remplit sans jamais agrandir son conteneur.
        Color.clear.overlay {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    if let fallback { AnyView(Thumb(url: fallback)) } else { AnyView(placeholder) }
                default: placeholder
                }
            }
        }
        .clipped()
    }
    private var placeholder: some View {
        LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SkeletonLine: View {
    let width: CGFloat
    @State private var on = false
    var body: some View {
        Capsule().fill(.white.opacity(on ? 0.35 : 0.15)).frame(width: width, height: 9)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

/// Mots-clés de la photo, en petites pastilles sur plusieurs lignes.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing; line = max(line, s.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX, x > b.minX { x = b.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

struct SkeletonCard: View {
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(on ? 0.08 : 0.04))
            .aspectRatio(16 / 10, contentMode: .fit)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}

struct Chip: View {
    let label: String
    let icon: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 28)
                .foregroundStyle(on ? .black : .white.opacity(0.75))
                .background(Capsule().fill(on ? .white : .white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

struct Badge: View {
    let text: String
    var dark = false
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).tracking(0.3)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(dark ? .black.opacity(0.55) : .white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }
}

struct Empty: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.35))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorState: View {
    let text: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.4))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            Button("Réessayer", action: retry).buttonStyle(GlassButton())
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrimaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, compact ? 16 : 14).frame(height: compact ? 36 : 40)
            .foregroundStyle(.black)
            .background(Capsule().fill(.white))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .contentShape(Capsule())
    }
}
