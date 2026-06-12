import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case zh = "zh"
    case en = "en"
    case ja = "ja"
    case de = "de"
    case fr = "fr"
    case es = "es"
    case ru = "ru"

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ru: return "Русский"
        }
    }
}

struct Localization {
    static let dict: [String: [String: String]] = [
        "设置": [
            "en": "Settings",
            "ja": "設定",
            "de": "Einstellungen",
            "fr": "Paramètres",
            "es": "Configuración",
            "ru": "Настройки"
        ],
        "可通过 ⌘, 打开本页。": [
            "en": "You can open this page with ⌘,.",
            "ja": "⌘, でこのページを開くことができます。",
            "de": "Sie können diese Seite mit ⌘, öffnen.",
            "fr": "Vous pouvez ouvrir cette page avec ⌘,.",
            "es": "Puedes abrir esta página con ⌘,.",
            "ru": "Вы можете открыть эту страницу с помощью ⌘,."
        ],
        "关联常见视频格式": [
            "en": "Associate Common Video Formats",
            "ja": "一般的な動画形式を関連付ける",
            "de": "Häufige Videoformate verknüpfen",
            "fr": "Associer les formats vidéo courants",
            "es": "Asociar formatos de video comunes",
            "ru": "Ассоциировать популярные видеоформаты"
        ],
        "快捷键": [
            "en": "Shortcuts",
            "ja": "ショートカットキー",
            "de": "Tastenkombinationen",
            "fr": "Raccourcis",
            "es": "Atajos",
            "ru": "Горячие клавиши"
        ],
        "左右方向键跳转秒数": [
            "en": "Left/Right seek seconds",
            "ja": "左右方向キーのスキップ秒数",
            "de": "Sekunden für Links-/Rechtstasten",
            "fr": "Secondes de recherche Gauche/Droite",
            "es": "Segundos de búsqueda Izq/Der",
            "ru": "Секунды перемотки влево/вправо"
        ],
        "秒数": [
            "en": "Seconds",
            "ja": "秒数",
            "de": "Sekunden",
            "fr": "Secondes",
            "es": "Segundos",
            "ru": "Секунды"
        ],
        "上下方向键跳转帧数": [
            "en": "Up/Down frame step count",
            "ja": "上下方向キーのスキップフレーム数",
            "de": "Frames für Auf-/Abtasten",
            "fr": "Images de recherche Haut/Bas",
            "es": "Fotogramas de búsqueda Arriba/Abajo",
            "ru": "Кадры перемотки вверх/вниз"
        ],
        "帧数": [
            "en": "Frames",
            "ja": "フレーム数",
            "de": "Bilder",
            "fr": "Images",
            "es": "Fotogramas",
            "ru": "Кадры"
        ],
        "左/右：按设定秒数后退/前进；上/下：按设定帧数后退/前进。": [
            "en": "Left/Right: Rewind/Forward by set seconds; Up/Down: Rewind/Forward by set frames.",
            "ja": "左/右：設定秒数で戻る/進む、上/下：設定フレーム数で戻る/進む。",
            "de": "Links/Rechts: Zurück/Vor um eingestellte Sekunden; Auf/Ab: Zurück/Vor um eingestellte Frames.",
            "fr": "Gauche/Droite : Reculer/Avancer du nombre de secondes défini ; Haut/Bas : Reculer/Avancer du nombre d'images défini.",
            "es": "Izquierda/Derecha: Retroceder/Avanzar según los segundos configurados; Arriba/Abajo: Retroceder/Avanzar según los fotogramas configurados.",
            "ru": "Влево/Вправо: Назад/Вперед на заданные секунды; Вверх/Вниз: Назад/Вперед на заданные кадры."
        ],
        "上一文件快捷键": [
            "en": "Prev File Shortcut",
            "ja": "前のファイル",
            "de": "Vorherige Datei",
            "fr": "Fichier précédent",
            "es": "Archivo anterior",
            "ru": "Предыдущий файл"
        ],
        "上一": [
            "en": "Prev",
            "ja": "前へ",
            "de": "Zurück",
            "fr": "Précédent",
            "es": "Anterior",
            "ru": "Пред."
        ],
        "下一": [
            "en": "Next",
            "ja": "次へ",
            "de": "Weiter",
            "fr": "Suivant",
            "es": "Siguiente",
            "ru": "След."
        ],
        "默认上一文件是 `[`，下一文件是 `]`，按物理键位处理，不受中英文输入影响。速度调节为 `;` 和 `'`。": [
            "en": "Default previous file is `[`, next file is `]`, processed by physical key position. Speed adjustments are `;` and `'`.",
            "ja": "デフォルトで前のファイルは `[`、次のファイルは `]`（物理キーボード位置による）。速度調整は `;` と `'`。",
            "de": "Standardmäßig vorherige Datei ist `[`, nächste ist `]` (physische Tasten). Geschwindigkeitseinstellung mit `;` und `'`.",
            "fr": "Fichier précédent par défaut `[`, suivant `]`, géré par la position physique des touches. Réglage de la vitesse avec `;` et `'`.",
            "es": "El archivo anterior por defecto es `[`, el siguiente es `]`, procesado por la posición física de la tecla. Los ajustes de velocidad son `;` y `'`.",
            "ru": "По умолчанию пред. файл — `[`, след. — `]`, обрабатывается по физическому положению клавиш. Изменение скорости — `;` и `'`."
        ],
        "音频步进快捷键": [
            "en": "Audio Delay Shortcut",
            "ja": "音声遅延ショートカットキー",
            "de": "Audio-Verzögerung Shortcut",
            "fr": "Raccourci de décalage audio",
            "es": "Atajo de retraso de audio",
            "ru": "Задержка звука"
        ],
        "减小": [
            "en": "Decrease",
            "ja": "減らす",
            "de": "Verringern",
            "fr": "Diminuer",
            "es": "Disminuir",
            "ru": "Уменьшить"
        ],
        "增加": [
            "en": "Increase",
            "ja": "増やす",
            "de": "Erhöhen",
            "fr": "Augmenter",
            "es": "Aumentar",
            "ru": "Увеличить"
        ],
        "倍速切换快捷键": [
            "en": "Speed Toggle Shortcut",
            "ja": "倍速切り替えショートカットキー",
            "de": "Tastenkombination für Geschwindigkeitswechsel",
            "fr": "Raccourci de bascule de vitesse",
            "es": "Atajo de cambio de velocidad",
            "ru": "Переключение скорости"
        ],
        "默认音频步进为 `,` 和 `.`，倍速切换为 `=`，按物理键位处理。": [
            "en": "Default audio delay step is `,` and `.`, speed toggle is `=`, processed by physical keys.",
            "ja": "デフォルトの音声遅延は `,` と `.`、倍速切り替え是 `=`（物理キーボード位置による）。",
            "de": "Standard-Audio-Schritt ist `,` und `.`, Geschwindigkeitswechsel ist `=` (physische Tasten).",
            "fr": "Décalage audio par défaut `,` et `.`, bascule de vitesse `=`, géré par les touches physiques.",
            "es": "El retraso de audio por defecto es `,` y `.`, el cambio de velocidad es `=`, procesado por teclas físicas.",
            "ru": "По умолчанию задержка звука —, и ., переключение скорости — =, обрабатывается по физическим клавишам."
        ],
        "打开文件时窗口": [
            "en": "Window on Open",
            "ja": "ファイルを開くときのウィンドウ",
            "de": "Fenster beim Öffnen",
            "fr": "Fenêtre à l'ouverture",
            "es": "Ventana al abrir",
            "ru": "Окно при открытии файла"
        ],
        "默认最大化。尽量大表示按视频比例尽可能铺满屏幕可视区域，不强行加黑边占满。": [
            "en": "Default is maximized. 'As large as possible' scales the window to fit the screen while keeping the video aspect ratio without borders.",
            "ja": "デフォルトは最大化。「できるだけ大きく」は、アスペクト比を維持し、黒帯を追加せずに画面内に収めます。",
            "de": "Standardmäßig maximiert. 'So groß wie möglich' bedeutet, dass das Fenster dem Video-Seitenverhältnis entsprechend vergrößert wird.",
            "fr": "Maximisé par défaut. 'Aussi grand que possible' adapte la fenêtre au format vidéo sans ajouter de bandes noires.",
            "es": "Maximizada por defecto. 'Lo más grande posible' significa que la ventana se adapta a la proporción de video sin agregar bordes negros.",
            "ru": "По умолчанию максимизировано. 'Как можно больше' подгоняет размер окна под пропорции видео без черных полос."
        ],
        "允许多窗口": [
            "en": "Allow Multiple Windows",
            "ja": "マルチウィンドウを許可",
            "de": "Mehrere Fenster erlauben",
            "fr": "Autoriser plusieurs fenêtres",
            "es": "Permitir múltiples ventanas",
            "ru": "Разрешить несколько окон"
        ],
        "关闭后，新打开的文件会直接在当前窗口播放，不另开新窗口。": [
            "en": "When disabled, newly opened files will play in the current window instead of a new one.",
            "ja": "無効にすると、新しく開いたファイルは新しいウィンドウではなく現在のウィンドウで再生されます。",
            "de": "Wenn deaktiviert, werden neu geöffnete Dateien im aktuellen Fenster abgespielt.",
            "fr": "Une fois désactivé, les nouveaux fichiers s'ouvriront dans la fenêtre active.",
            "es": "Si se desactiva, los nuevos archivos se reproducirán en la ventana actual.",
            "ru": "Если отключено, новые файлы будут проигрываться в текущем окне."
        ],
        "显示最近播放": [
            "en": "Show Recent Files",
            "ja": "最近の再生を表示",
            "de": "Kürzlich abgespielt anzeigen",
            "fr": "Afficher les fichiers récents",
            "es": "Mostrar archivos recientes",
            "ru": "Показывать недавние"
        ],
        "开启后，当没有播放任何文件时，将显示最近播放的文件列表。": [
            "en": "When enabled, a list of recently played files will be displayed when no file is playing.",
            "ja": "有効にすると、ファイルを再生していないときに最近再生したファイルのリストが表示されます。",
            "de": "Wenn aktiviert, wird eine Liste der kürzlich abgespielten Dateien angezeigt, wenn kein Video läuft.",
            "fr": "Une fois activé, affiche la liste des fichiers récents quand rien n'est en lecture.",
            "es": "Si se activa, se mostrará la lista de archivos reproducidos recientemente cuando no se reproduzca nada.",
            "ru": "Если включено, при отсутствии воспроизведения будет показан список недавних файлов."
        ],
        "音频延迟步进": [
            "en": "Audio Delay Step",
            "ja": "音声遅延ステップ",
            "de": "Audio-Verzögerungsschritt",
            "fr": "Pas de décalage audio",
            "es": "Paso de retraso de audio",
            "ru": "Шаг задержки звука"
        ],
        "音频延迟步进决定每次按音频步进快捷键时延迟的增减量，每个文件的延迟值独立记忆。": [
            "en": "The audio delay step determines the change in delay per shortcut press. Each file's delay is saved individually.",
            "ja": "音声遅延ステップは、ショートカットキーを押したときの遅延の増減量を決定します。ファイルごとに保存されます。",
            "de": "Der Verzögerungsschritt bestimmt die Änderung pro Tastendruck. Die Verzögerung wird für jede Datei separat gespeichert.",
            "fr": "Le pas de décalage audio détermine la variation de décalage par pression de touche. Mémorisé pour chaque fichier.",
            "es": "El paso de retraso de audio determina el cambio de retraso por pulsación. Cada archivo lo recuerda de forma independiente.",
            "ru": "Шаг задержки звука определяет изменение задержки за одно нажатие. Сохраняется для каждого файла отдельно."
        ],
        "界面语言": [
            "en": "Language",
            "ja": "言語",
            "de": "Sprache",
            "fr": "Langue",
            "es": "Idioma",
            "ru": "Язык"
        ],
        "自动检测": [
            "en": "Auto Detect",
            "ja": "自動検出",
            "de": "Automatisch",
            "fr": "Détection automatique",
            "es": "Detección automática",
            "ru": "Авто"
        ],
        "播放列表": [
            "en": "Playlist",
            "ja": "プレイリスト",
            "de": "Wiedergabeliste",
            "fr": "Liste de lecture",
            "es": "Lista de reproducción",
            "ru": "Плейлист"
        ],
        "最近播放": [
            "en": "Recent Plays",
            "ja": "最近の再生",
            "de": "Zuletzt abgespielt",
            "fr": "Récents",
            "es": "Reproducción reciente",
            "ru": "Недавние"
        ],
        "打开文件位置": [
            "en": "Reveal in Finder",
            "ja": "ファイルの場所を開く",
            "de": "Im Finder anzeigen",
            "fr": "Afficher dans le Finder",
            "es": "Mostrar en Finder",
            "ru": "Показать в Finder"
        ],
        "显示文件时长": [
            "en": "Show duration",
            "ja": "ファイルの再生時間を表示",
            "de": "Dateidauer anzeigen",
            "fr": "Afficher la durée du fichier",
            "es": "Mostrar duración de archivo",
            "ru": "Показать длительность файла"
        ],
        "显示全部视频时长": [
            "en": "Show all durations",
            "ja": "すべての再生時間を表示",
            "de": "Alle Dauern anzeigen",
            "fr": "Afficher toutes les durées",
            "es": "Mostrar todas las duraciones",
            "ru": "Показать длительность всех"
        ],
        "音频轨道": [
            "en": "Audio Track",
            "ja": "音声トラック",
            "de": "Audiospur",
            "fr": "Piste audio",
            "es": "Pista de audio",
            "ru": "Аудиодорожка"
        ],
        "无可用音轨": [
            "en": "No audio track available",
            "ja": "利用可能な音轨はありません",
            "de": "Keine Audiospur verfügbar",
            "fr": "Aucune piste audio disponible",
            "es": "No hay pistas de audio disponibles",
            "ru": "Нет доступных аудиодорожек"
        ],
        "字幕": [
            "en": "Subtitle",
            "ja": "字幕",
            "de": "Untertitel",
            "fr": "Sous-titres",
            "es": "Subtítulos",
            "ru": "Субтитры"
        ],
        "内置字幕": [
            "en": "Embedded Subtitle",
            "ja": "内蔵字幕",
            "de": "Integrierte Untertitel",
            "fr": "Sous-titres intégrés",
            "es": "Subtítulos integrados",
            "ru": "Встроенные subтитры"
        ],
        "无内置字幕": [
            "en": "No embedded subtitle",
            "ja": "内蔵字幕なし",
            "de": "Keine integrierten Untertitel",
            "fr": "Aucun sous-titre intégré",
            "es": "Sin subtítulos integrados",
            "ru": "Нет встроенных субтитров"
        ],
        "外挂字幕": [
            "en": "External Subtitle",
            "ja": "外付け字幕",
            "de": "Externe Untertitel",
            "fr": "Sous-titres externes",
            "es": "Subtítulos externos",
            "ru": "Внешние субтитры"
        ],
        "无匹配外挂字幕": [
            "en": "No matching external subtitle",
            "ja": "一致する外付け字幕なし",
            "de": "Keine passenden externen Untertitel",
            "fr": "Aucun sous-titre externe assorti",
            "es": "Sin subtítulos externos coincidentes",
            "ru": "Нет подходящих внешних субтитров"
        ],
        "字幕背景透明度": [
            "en": "Subtitle Background Opacity",
            "ja": "字幕背景不透明度",
            "de": "Untertitel Hintergrunddeckkraft",
            "fr": "Opacité de l'arrière-plan des sous-titres",
            "es": "Opacidad del fondo del subtítulo",
            "ru": "Прозрачность фона субтитров"
        ],
        "字幕字体大小": [
            "en": "Subtitle Font Size",
            "ja": "字幕のフォントサイズ",
            "de": "Untertitel-Schriftgröße",
            "fr": "Taille de police des sous-titres",
            "es": "Tamaño de fuente del subtítulo",
            "ru": "Размер шрифта субтитров"
        ],
        "文件信息": [
            "en": "File Info",
            "ja": "ファイル情報",
            "de": "Datei-Info",
            "fr": "Infos sur le fichier",
            "es": "Información del archivo",
            "ru": "Информация о файле"
        ],
        "复制全部": [
            "en": "Copy All",
            "ja": "すべてコピー",
            "de": "Alles kopieren",
            "fr": "Tout copier",
            "es": "Copiar todo",
            "ru": "Копировать все"
        ],
        "关闭字幕": [
            "en": "Disable subtitle",
            "ja": "字幕をオフにする",
            "de": "Untertitel ausschalten",
            "fr": "Désactiver les sous-titres",
            "es": "Desactivar subtítulos",
            "ru": "Выключить субтитры"
        ],
        "已关闭当前文件": [
            "en": "Closed current file",
            "ja": "現在のファイルを閉じました",
            "de": "Aktuelle Datei geschlossen",
            "fr": "Fichier actuel fermé",
            "es": "Archivo actual cerrado",
            "ru": "Текущий файл закрыт"
        ],
        "速度: %.2fx": [
            "en": "Speed: %.2fx",
            "ja": "速度: %.2fx",
            "de": "Geschwindigkeit: %.2fx",
            "fr": "Vitesse : %.2fx",
            "es": "Velocidad: %.2fx",
            "ru": "Скорость: %.2fx"
        ],
        "字幕：已关闭": [
            "en": "Subtitle: Disabled",
            "ja": "字幕：オフ",
            "de": "Untertitel: Deaktiviert",
            "fr": "Sous-titres : Désactivés",
            "es": "Subtítulo: Desactivado",
            "ru": "Субтитры: Выключены"
        ],
        "字幕：": [
            "en": "Subtitle: ",
            "ja": "字幕：",
            "de": "Untertitel: ",
            "fr": "Sous-titres : ",
            "es": "Subtítulo: ",
            "ru": "Субтитры: "
        ],
        "音频延迟: %.0f ms": [
            "en": "Audio Delay: %.0f ms",
            "ja": "音声遅延: %.0f ms",
            "de": "Audio-Verzögerung: %.0f ms",
            "fr": "Décalage audio : %.0f ms",
            "es": "Retraso de audio: %.0f ms",
            "ru": "Задержка звука: %.0f мс"
        ],
        "音频延迟: 已重置": [
            "en": "Audio Delay: Reset",
            "ja": "音声遅延: リセット",
            "de": "Audio-Verzögerung: Zurückgesetzt",
            "fr": "Décalage audio : Réinitialisé",
            "es": "Retraso de audio: Restablecido",
            "ru": "Задержка звука: Сброшена"
        ],
        "音频轨道已切换": [
            "en": "Audio track switched",
            "ja": "音声トラックを切り替えました",
            "de": "Audiospur gewechselt",
            "fr": "Piste audio changée",
            "es": "Pista de audio cambiada",
            "ru": "Аудиодорожка переключена"
        ],
        "内置字幕已切换": [
            "en": "Embedded subtitle track switched",
            "ja": "内蔵字幕を切り替えました",
            "de": "Integrierter Untertitel gewechselt",
            "fr": "Sous-titres intégrés changés",
            "es": "Subtítulo integrado cambiado",
            "ru": "Встроенные субтитры переключены"
        ],
        "播放失败": [
            "en": "Playback Failed",
            "ja": "再生失敗",
            "de": "Wiedergabe fehlgeschlagen",
            "fr": "Échec de la lecture",
            "es": "Reproducción fallida",
            "ru": "Ошибка воспроизведения"
        ],
        "确定": [
            "en": "OK",
            "ja": "確定",
            "de": "OK",
            "fr": "OK",
            "es": "Aceptar",
            "ru": "OK"
        ],
        "未执行格式关联": [
            "en": "Formats not associated",
            "ja": "フォーマット関連付けは未実行です",
            "de": "Formate nicht verknüpft",
            "fr": "Formats non associés",
            "es": "Formatos no asociados",
            "ru": "Ассоциация форматов не выполнялась"
        ],
        "关联失败：系统拒绝更新 LaunchServices。": [
            "en": "Association failed: System rejected LaunchServices update.",
            "ja": "関連付けに失敗しました：システムが LaunchServices の更新を拒否しました。",
            "de": "Verknüpfung fehlgeschlagen: System hat LaunchServices-Aktualisierung abgelehnt.",
            "fr": "Échec de l'association : Le système a rejeté la mise à jour de LaunchServices.",
            "es": "Error de asociación: El sistema rechazó actualizar LaunchServices.",
            "ru": "Ошибка ассоциации: Система отклонила обновление LaunchServices."
        ],
        "已注册并关联：%@": [
            "en": "Registered and associated: %@",
            "ja": "登録され関連付けられました：%@",
            "de": "Registriert und verknüpft: %@",
            "fr": "Enregistré et associé : %@",
            "es": "Registrado y asociado: %@",
            "ru": "Зарегистрировано и ассоциировано: %@"
        ],
        "已强制刷新并关联：%@": [
            "en": "Force refreshed and associated: %@",
            "ja": "強制更新され関連付けられました：%@",
            "de": "Aktualisierung erzwungen und verknüpft: %@",
            "fr": "Actualisé de force et associé : %@",
            "es": "Actualizado por la fuerza y asociado: %@",
            "ru": "Принудительно обновлено и ассоциировано: %@"
        ],
        "关联失败：%@；请确认程序位于 /Applications/BZPlayer.app": [
            "en": "Association failed: %@; Please make sure the app is in /Applications/BZPlayer.app",
            "ja": "関連付けに失敗しました：%@；アプリが /Applications/BZPlayer.app にあることを確認してください。",
            "de": "Verknüpfung fehlgeschlagen: %@; Bitte stellen Sie sicher, dass sich die App unter /Applications/BZPlayer.app befindet.",
            "fr": "Échec de l'association : %@ ; Veuillez vous assurer que l'application est dans /Applications/BZPlayer.app",
            "es": "Error de asociación: %@; Asegúrese de que la aplicación esté en /Applications/BZPlayer.app",
            "ru": "Ошибка ассоциации: %@; Пожалуйста, убедитесь, что приложение находится в /Applications/BZPlayer.app"
        ],
        "部分成功，已关联：%@；失败：%@；请确认程序位于 /Applications/BZPlayer.app": [
            "en": "Partially successful, associated: %@; Failed: %@; Please make sure the app is in /Applications/BZPlayer.app",
            "ja": "一部成功、関連付け：%@；失敗：%@；アプリが /Applications/BZPlayer.app にあることを確認してください。",
            "de": "Teilweise erfolgreich, verknüpft: %@; Fehlgeschlagen: %@; Bitte stellen Sie sicher, dass sich die App unter /Applications/BZPlayer.app befindet.",
            "fr": "Succès partiel, associé : %@ ; Échec : %@ ; Veuillez vous assurer que l'application est dans /Applications/BZPlayer.app",
            "es": "Parcialmente exitoso, asociado: %@; Fallido: %@; Asegúrese de que la aplicación esté en /Applications/BZPlayer.app",
            "ru": "Частичный успех, ассоциировано: %@; Ошибка: %@; Пожалуйста, убедитесь, что приложение находится в /Applications/BZPlayer.app"
        ],
        "打开文件": [
            "en": "Open File",
            "ja": "ファイルを開く",
            "de": "Datei öffnen",
            "fr": "Ouvrir",
            "es": "Abrir archivo",
            "ru": "Открыть файл"
        ],
        "当前：%.2fx": [
            "en": "Current: %.2fx",
            "ja": "現在: %.2fx",
            "de": "Aktuell: %.2fx",
            "fr": "Actuel : %.2fx",
            "es": "Actual: %.2fx",
            "ru": "Сейчас: %.2fx"
        ],
        "速度：": [
            "en": "Speed: ",
            "ja": "速度: ",
            "de": "Geschw: ",
            "fr": "Vitesse : ",
            "es": "Velocidad: ",
            "ru": "Скорость: "
        ],
        "播放链路：系统原生": [
            "en": "Engine: Native AVPlayer",
            "ja": "再生リンク：システムネイティブ",
            "de": "Wiedergabe-Engine: Systemnativ",
            "fr": "Moteur de lecture : Système natif",
            "es": "Motor de reproducción: Nativo del sistema",
            "ru": "Движок: Системный native"
        ],
        "播放链路：VLC/libvlc": [
            "en": "Engine: VLC/libvlc",
            "ja": "再生リンク：VLC/libvlc",
            "de": "Wiedergabe-Engine: VLC/libvlc",
            "fr": "Moteur de lecture : VLC/libvlc",
            "es": "Motor de reproducción: VLC/libvlc",
            "ru": "Движок: VLC/libvlc"
        ],
        "播放列表共 %d 个文件，总时长: %@": [
            "en": "Playlist: %d files, total duration: %@",
            "ja": "プレイリストに計 %d 個のファイル、総再生時間: %@",
            "de": "Wiedergabeliste: %d Dateien, Gesamtdauer: %@",
            "fr": "Liste de lecture : %d fichiers, durée totale : %@",
            "es": "Lista: %d archivos, duración total: %@",
            "ru": "В плейлисте %d файлов, общая длительность: %@"
        ],
        "选中 %d 个文件，总时长: %@": [
            "en": "Selected %d files, total duration: %@",
            "ja": "選択された %d 個のファイル、総再生时间: %@",
            "de": "%d Dateien ausgewählt, Gesamtdauer: %@",
            "fr": "%d fichiers sélectionnés, durée totale : %@",
            "es": "%d archivos seleccionados, duración total: %@",
            "ru": "Выбрано %d файлов, общая длительность: %@"
        ],
        "已将文件移入废纸篓": [
            "en": "Moved file to Trash",
            "ja": "ファイルをゴミ箱に移動しました",
            "de": "Datei in den Papierkorb verschoben",
            "fr": "Fichier déplacé dans la corbeille",
            "es": "Archivo movido a la papelera",
            "ru": "Файл перемещен в корзину"
        ],
        "无法将文件移入废纸篓": [
            "en": "Failed to move file to Trash",
            "ja": "ファイルをゴミ箱に移動できませんでした",
            "de": "Datei konnte nicht in den Papierkorb verschoben werden",
            "fr": "Échec du déplacement dans la corbeille",
            "es": "Error al mover el archivo a la papelera",
            "ru": "Не удалось переместить файл в корзину"
        ]
    ]

    static func translate(_ key: String, for lang: String) -> String {
        guard lang != "zh" else { return key }
        if let langDict = dict[key], let val = langDict[lang] {
            return val
        }
        return key
    }
}
