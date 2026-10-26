import Foundation
import os

// Noms des photos Wallhaven. La recherche de Wallhaven ne renvoie pas de titre : on lit les
// mots-clés de chaque photo affichée (une requête par photo, 45 par minute au maximum),
// et on en fait un nom en français : « Kuang Si falls, Laos », « Montagnes, Japon »…
// Les noms sont gardés en cache : une photo déjà vue est nommée tout de suite.

struct PhotoName: Codable, Equatable {
    var title: String
    var credit: String?        // « Photo de … » / « Illustration de … »
    var tags: [String]         // mots-clés en français, pour l'aperçu
}

@MainActor
final class PhotoNames: ObservableObject {
    static let shared = PhotoNames()
    @Published private(set) var names: [String: PhotoName] = [:]
    private var raw: [String: [[String]]] = [:]   // mots-clés bruts [nom, catégorie] : les noms sont recalculés au lancement
    private var queue: [String] = []           // les dernières photos affichées passent en premier
    private var pumping = false
    private var dirty = false
    private let log = Logger(subsystem: "com.osalabs.osawallpaper", category: "names")

    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.osalabs.osawallpaper/photo-tags.json")

    private init() {
        if let d = try? Data(contentsOf: Self.file), let r = try? JSONDecoder().decode([String: [[String]]].self, from: d) {
            raw = r
            names = r.mapValues { Self.name(from: $0.map { ($0[0], $0.count > 1 ? $0[1] : "") }) }
        }
        if Demo.on, let f = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO_TAGS"],
           let d = try? Data(contentsOf: URL(fileURLWithPath: f)), let r = try? JSONDecoder().decode([String: [[String]]].self, from: d) {
            for (k, v) in r { names[k] = Self.name(from: v.map { ($0[0], $0.count > 1 ? $0[1] : "") }) }
        }
    }

    /// La photo est à l'écran : on veut son nom (en priorité si `urgent`, ex. sélectionnée).
    func want(_ id: String, urgent: Bool = false) {
        guard names[id] == nil else { return }
        queue.removeAll { $0 == id }
        queue.append(id)
        if urgent { queue.append(id) }
        pump()
    }

    /// La photo a quitté l'écran : inutile de la nommer maintenant.
    func forget(_ id: String) { queue.removeAll { $0 == id } }

    private func pump() {
        guard !pumping, let id = queue.popLast() else { return }
        pumping = true
        Task {
            var wait: UInt64 = 1_400_000_000                       // 45 requêtes / minute
            do {
                var r = URLRequest(url: URL(string: "https://wallhaven.cc/api/v1/w/\(id)")!, timeoutInterval: 15)
                r.setValue("OsaWallpaper (https://github.com/osayanis/osawallpaper)", forHTTPHeaderField: "User-Agent")
                let (d, resp) = try await URLSession.shared.data(for: r)
                if (resp as? HTTPURLResponse)?.statusCode == 429 {
                    queue.append(id); wait = 20_000_000_000          // trop de requêtes : on patiente
                } else if let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let data = j["data"] as? [String: Any], let tags = data["tags"] as? [[String: Any]] {
                    let pairs = tags.compactMap { t in (t["name"] as? String).map { ($0, t["category"] as? String ?? "") } }
                    raw[id] = pairs.map { [$0.0, $0.1] }
                    names[id] = Self.name(from: pairs)
                    save()
                }
            } catch {
                log.error("nom de \(id, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: wait)
            pumping = false
            pump()
        }
    }

    private func save() {
        guard !dirty, !Demo.on else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.dirty = false
            if let d = try? JSONEncoder().encode(self.raw) { try? d.write(to: Self.file) }
        }
    }

    // MARK: Du mot-clé au nom

    private static let places: Set<String> = ["Location", "Countries", "Cities", "Landmarks", "Places"]
    // catégories où un nom propre désigne un lieu ou un objet photographié (pas un style, une religion…)
    private static let spotKinds: Set<String> = ["Location", "Cities", "Landmarks", "Places", "Landscapes", "Architecture", "Nature",
                                                 "Other", "Space", "Aircraft", "Vehicles", "Sports"]
    private static let people: Set<String> = ["Photographers", "Artists"]
    private static let noise: Set<String> = ["Photography", "Art & Design", "Digital", "Technology", "Colors", "Anime & Manga", "Music", "People", "Knowledge", "Websites", "Companies"]
    // sites et marques souvent présents dans les mots-clés : jamais un nom de photo
    private static let brands: Set<String> = ["unsplash", "pexels", "pixabay", "flickr", "500px", "artstation", "deviantart", "instagram",
                                              "photoshop", "lightroom", "nikon", "canon", "sony", "dji", "4k", "8k", "cgi", "hdr", "4k ultra hd"]
    private static let generic: Set<String> = [
        "nature", "landscape", "outdoors", "photography", "digital art", "artwork", "illustration", "digital painting",
        "4k", "8k", "wide screen", "ultrawide", "wallpaper", "sky", "clouds", "water", "trees", "plants", "foliage",
        "sunlight", "aerial view", "drone photo", "wide angle", "simple background", "centered", "dark", "minimalism",
        "monochrome", "signature", "watermarked", "reflection", "leaves", "rocks", "isolated", "cgi", "japanese", "architecture",
    ]

    static func name(from tags: [(name: String, category: String)]) -> PhotoName {
        let credit = tags.first { people.contains($0.category) }
        let isArt = tags.contains { ["digital art", "artwork", "illustration", "digital painting", "cgi"].contains($0.name.lowercased()) }
        let country = tags.first { $0.category == "Countries" }?.name
        // Lieu précis : un nom propre (Kuang Si falls, Seiganto-ji, Skradinski Buk Waterfall…)
        let spot = tags.first { t in
            t.name != country && spotKinds.contains(t.category)
                && t.name.first?.isUppercase == true && t.name.count > 3 && fr[t.name.lowercased()] == nil
                && !brands.contains(t.name.lowercased()) && !generic.contains(t.name.lowercased())
                && !t.name.hasSuffix("ese") && !t.name.hasSuffix("ian") && !t.name.hasSuffix("ish")   // Japanese, Italian, British…
        }?.name
        let subjects = tags.filter { t in
            !people.contains(t.category) && !noise.contains(t.category) && !places.contains(t.category) && t.category != "Religion"
                && !generic.contains(t.name.lowercased()) && !brands.contains(t.name.lowercased()) && t.name.first?.isUppercase != true
        }.map(\.name)

        var title: String
        if let spot { title = spot + (country.map { ", " + french($0) } ?? "") }
        else if let s = subjects.first { title = french(s).capitalizedFirst + (country.map { ", " + french($0) } ?? subjects.dropFirst().first.map { " et " + french($0) } ?? "") }
        else if let country { title = french(country) }
        else { title = isArt ? "Illustration" : "Photo" }

        let shown = (subjects + tags.filter { places.contains($0.category) }.map(\.name)).prefix(8).map { french($0).capitalizedFirst }
        return PhotoName(title: title, credit: credit.map { (isArt ? "Illustration de " : "Photo de ") + $0.name }, tags: Array(shown))
    }

    static func french(_ en: String) -> String { fr[en.lowercased()] ?? en }

    /// Recherche tapée en français → mots-clés anglais de Wallhaven. Les mots inconnus
    /// (Tokyo, Islande, noms propres…) passent tels quels.
    /// `knownOnly` : ne garde que les mots traduits (2e essai quand la recherche ne trouve rien).
    static func english(_ query: String, knownOnly: Bool = false) -> String {
        var q = " " + query.lowercased().folding(options: .diacriticInsensitive, locale: nil) + " "
        var known: [String] = []
        for (f, e) in toEnglish.sorted(by: { $0.key.count > $1.key.count }) {   // expressions longues d'abord
            if q.contains(" \(f) ") {
                q = q.replacingOccurrences(of: " \(f) ", with: " ")
                known.append(e)
            }
        }
        let rest = knownOnly ? [] : q.split(separator: " ").map(String.init)
        return (known + rest).joined(separator: " ")
    }

    private static let toEnglish: [String: String] = {
        var d: [String: String] = [:]
        for (e, f) in fr { d[f.lowercased().folding(options: .diacriticInsensitive, locale: nil)] = e }
        // pluriels et synonymes courants
        let extra: [String: String] = [
            "montagne": "mountains", "montagnes": "mountains", "mer": "sea", "ocean": "ocean", "plages": "beach",
            "foret": "forest", "forets": "forest", "lacs": "lake", "villes": "city", "etoile": "stars", "etoiles": "stars",
            "voie lactee": "milky way", "ciel etoile": "starry night", "aurore boreale": "aurora", "aurores boreales": "aurora",
            "coucher de soleil": "sunset", "couchers de soleil": "sunset", "lever de soleil": "sunrise", "chute d'eau": "waterfall",
            "cascades": "waterfall", "voiture": "cars", "voitures": "cars", "chat": "cats", "chats": "cats", "chien": "dogs",
            "chiens": "dogs", "fleur": "flowers", "neige": "snow", "hiver": "winter", "automne": "fall", "ete": "summer",
            "printemps": "spring", "enneige": "snow", "enneigee": "snow", "enneiges": "snow", "enneigees": "snow",
            "paysage": "landscape", "paysages": "landscape", "nature": "nature", "arbre": "trees", "arbres": "trees",
            "lune": "moon", "soleil": "sun", "riviere": "river", "fleuve": "river", "desert": "desert", "ile": "island", "iles": "island", "nuit": "night", "espace": "space", "planete": "planet", "planetes": "planet",
            "minimaliste": "minimalism", "abstrait": "abstract", "japon": "Japan", "etats-unis": "USA", "islande": "Iceland",
        ]
        d.merge(extra) { _, new in new }
        return d
    }()

    /// Mots-clés anglais de Wallhaven les plus courants → français.
    static let fr: [String: String] = [
        "mountains": "montagnes", "mountain top": "sommet", "snow covered": "enneigé", "snowy peak": "sommet enneigé",
        "lake": "lac", "river": "rivière", "sea": "mer", "ocean": "océan", "beach": "plage", "coast": "côte", "island": "île",
        "waterfall": "cascade", "forest": "forêt", "jungle": "jungle", "desert": "désert", "canyon": "canyon", "valley": "vallée",
        "hills": "collines", "field": "champ", "grass": "herbe", "flowers": "fleurs", "cherry blossom": "cerisiers en fleurs",
        "snow": "neige", "ice": "glace", "glacier": "glacier", "winter": "hiver", "fall": "automne", "summer": "été", "spring": "printemps",
        "sunset": "coucher de soleil", "sunrise": "lever de soleil", "night": "nuit", "starry night": "ciel étoilé", "stars": "étoiles",
        "milky way": "voie lactée", "aurora": "aurore boréale", "aurorae": "aurore boréale", "moon": "lune", "sun": "soleil",
        "space": "espace", "planet": "planète", "galaxy": "galaxie", "nebula": "nébuleuse", "earth": "Terre", "universe": "univers",
        "city": "ville", "cityscape": "ville", "city lights": "lumières de la ville", "skyscraper": "gratte-ciel", "street": "rue",
        "bridge": "pont", "building": "bâtiment", "house": "maison", "cabin": "cabane", "castle": "château", "church": "église",
        "temple": "temple", "tower": "tour", "lighthouse": "phare", "road": "route", "car": "voiture", "cars": "voitures",
        "vehicle": "véhicule", "train": "train", "airplane": "avion", "boat": "bateau", "ship": "navire", "rain": "pluie",
        "fog": "brouillard", "mist": "brume", "storm": "orage", "lightning": "éclair", "rainbow": "arc-en-ciel", "volcano": "volcan",
        "cats": "chats", "cat": "chat", "dogs": "chiens", "dog": "chien", "animals": "animaux", "birds": "oiseaux", "wolf": "loup",
        "deer": "cerf", "abstract": "abstrait", "minimalism": "minimalisme", "neon": "néon", "cyberpunk": "cyberpunk",
        "futuristic": "futuriste", "fantasy art": "fantasy", "wilderness": "nature sauvage", "window": "fenêtre", "angel": "ange",
        "wreckage": "épave", "fireworks": "feux d'artifice", "race tracks": "circuit", "destruction": "ruines", "ruins": "ruines",
        "windmill": "moulin", "pier": "ponton", "dock": "quai", "harbor": "port", "village": "village", "town": "village",
        "moss": "mousse", "palm trees": "palmiers", "sand": "sable", "dunes": "dunes", "clouds": "nuages", "sky": "ciel",
        // pays fréquents
        "japan": "Japon", "usa": "États-Unis", "iceland": "Islande", "norway": "Norvège", "switzerland": "Suisse", "italy": "Italie",
        "france": "France", "germany": "Allemagne", "spain": "Espagne", "croatia": "Croatie", "china": "Chine", "canada": "Canada",
        "new zealand": "Nouvelle-Zélande", "austria": "Autriche", "scotland": "Écosse", "greece": "Grèce", "saudi arabia": "Arabie saoudite",
        "south korea": "Corée du Sud", "indonesia": "Indonésie", "thailand": "Thaïlande", "vietnam": "Viêt Nam", "russia": "Russie",
        "united kingdom": "Royaume-Uni", "england": "Angleterre", "netherlands": "Pays-Bas", "portugal": "Portugal", "laos": "Laos",
        "australia": "Australie", "mexico": "Mexique", "brazil": "Brésil", "chile": "Chili", "argentina": "Argentine", "peru": "Pérou",
        "morocco": "Maroc", "egypt": "Égypte", "turkey": "Turquie", "india": "Inde", "nepal": "Népal", "finland": "Finlande",
        "sweden": "Suède", "denmark": "Danemark", "poland": "Pologne", "greenland": "Groenland",
    ]
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
