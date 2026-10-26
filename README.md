<div align="center">

<img src=".github/assets/icon.png" width="128" alt="Icône OsaWallpaper">

# OsaWallpaper

**Ton fond d'écran de Mac, façon écran verrouillé.**
L'heure en verre, la pochette du morceau en cours, la musique au bout de la souris.

macOS 14+ · SwiftUI natif · ~1,6 Mo · un projet [OsaLabs](https://osalabs.fr)

</div>

---

## Ce que ça fait

| | |
|---|---|
| 🕰️ **L'heure, en grand** | Date et horloge en verre en haut du bureau, comme sur l'écran verrouillé de l'iPhone. |
| 🎵 **La pochette devient le fond** | Quand un morceau joue dans Music ou Spotify, le bureau prend les couleurs de la pochette, floutée, et l'horloge se teinte avec. |
| 💿 **Pochette en relief** | Elle s'incline doucement vers ta souris. Un clic ouvre le lecteur. |
| ⏯️ **Lecteur en verre** | Titre, progression, favori, précédent / lecture / suivant, sortie audio. |
| 🎤 **Paroles synchronisées** | La ligne en cours s'affiche sous le lecteur (LRCLIB). |
| 🎧 **AirPods & casques** | Dès qu'un casque Bluetooth se connecte : une pastille avec sa batterie et le volume. La batterie reste visible à côté de la date. |
| ⚡ **Charge** | Branche ton Mac : une pastille « En charge » avec le pourcentage. |
| 🌤️ **Météo** | Température et ciel à côté de la date (Open-Meteo, sans clé ni compte). |
| 🖥️ **Tous les écrans** | Un fond par écran, écrans externes et Mac sans encoche compris. |

Les widgets restent **derrière toutes tes fenêtres** : ils n'apparaissent que sur le bureau, ne volent jamais le focus, et les clics passent au travers partout sauf sur les boutons.

## Installation

1. Ouvre `OsaWallpaper.dmg` et glisse l'app dans **Applications**.
2. Au premier lancement, autorise OsaWallpaper à **contrôler Music** (ou Spotify) : c'est ce qui lui permet de lire le morceau en cours.
3. L'icône 🖼️ dans la barre de menus donne accès aux réglages et à l'ouverture au démarrage.

> L'app n'est pas notarisée : si macOS refuse de l'ouvrir, fais **clic droit → Ouvrir** la première fois.

## Compiler

```bash
./build.sh            # → OsaWallpaper.app (release)
./make-dmg.sh         # → OsaWallpaper.dmg
```

Mode démo, sans toucher à tes apps de musique :

```bash
OSAWALLPAPER_DEMO=/chemin/vers/une/image.jpg ./OsaWallpaper.app/Contents/MacOS/OsaWallpaper
```

## Comment ça marche

- **Deux fenêtres par écran** : le fond au niveau du bureau (sous les icônes du Finder) et les widgets juste au-dessus des icônes, mais sous toutes les apps.
- **Clics** : la fenêtre des widgets ignore la souris, sauf quand le curseur passe sur une zone interactive. C'est la même technique que l'îlot d'[OsaNotch](https://notch.osalabs.fr).
- **Musique** : `osascript` en sous-processus, une seule requête à la fois. Le morceau n'est republié que s'il change ; la progression est calculée localement.
- **Casques** : la sortie audio par défaut est surveillée via CoreAudio, aucune permission Bluetooth. La batterie est lue dans `system_profiler`.
- **Sobriété** : environ 0,2 % de CPU à vide et 1,5 % pendant la lecture, autour de 30 Mo de RAM. Les paroles ne réveillent l'app qu'au début de chaque ligne.

---

<div align="center">
Fait par <a href="https://github.com/osayanis">Yanis</a> · OsaLabs
</div>
