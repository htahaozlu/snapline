# Nokta — Spesifikasyon (v0.1 + roadmap)

Girdi belgeleri: rakip ve davranış araştırması (bu repoda yayımlanmaz), `docs/DESIGN.md`.
Ürün adı Snapline; bu belgeler projenin çalışma adını (Nokta) kullanır.

## 1. Konum
macOS için **snap tarzı** pencere yöneticisi (tiling WM değil): pencereyi kenara/köşeye sürükle ya da
kısayola bas, pencere yerine otursun. Fark iddiaları — hepsi ölçülebilir veya `docs/INTEGRITY.md` ile
doğrulanabilir:

1. **Private API yok.** İncelenen 10 rakibin 10'u `_AXUIElementGetWindow` kullanıyor; Nokta private
   framework (SkyLight/CGS) veya private sembol linklemez, SIP'e dokunmaz. Dürüst dipnot: iki belgesiz
   AX öznitelik adı (`AXEnhancedUserInterface`, `AXFullScreen`, herkesin kullandığı string'ler) ve
   ekran kullanılabilir alanı için yalnız yedek olarak, `dlsym` ile çözülen export edilmiş-ama-header'sız
   bir HIToolbox fonksiyonu (`HIWindowGetAvailablePositioningBounds`; yoksa CGDisplayBounds). Kabuk
   ayrıca belgelenmemiş üç sistem arayüzünü **yalnız okur**: `com.apple.WindowManager` tercih anahtarları
   (macOS kenar döşemesi/Stage Manager durumu, Settings'te çakışma uyarısı için), `com.apple.accessibility.api`
   dağıtık bildirimi (izin değişince yeniden kontrol) ve "Play user interface sound effects" anahtarı
   `com.apple.sound.uiaudio.enabled` (ses kuralı). Hiçbirine yazılmaz.
2. **Sıfır ağ, sıfır telemetri, sıfır entitlement, sıfır üçüncü taraf framework**, hardened runtime.
   Güncelleme kontrolü yok (Rectangle/Tiles/Amethyst Sparkle ile ağa çıkar).
3. **Sentetik girdi yok.** Event tap yalnızca dinler (listen-only); `CGEventPost` hiç çağrılmaz
   (9 rakibin 7'si sentetik olay üretiyor).
4. **Olay tabanlı, polling yok.** AXObserver + Carbon hotkey + listen-only tap; idle CPU %0, wakeup ≈ 0.
5. **Ölçülen performans uygulamanın içinde gösterilir** (Settings › About) ve `docs/BENCHMARKS.md`'de
   yöntemiyle yayımlanır — rakiplerin hiçbirinde bağımsız ölçüm yok.
6. **Tasarım (v2):** Apple sadeliği + çizgi dili + tek kırmızı nokta (DESIGN.md). Önizleme, dokunulan
   kenardan kendini çizen tek bir çizgidir; iş bitince tek bir kırmızı nokta konur ("çizgi gösterir, nokta
   bitirir"). Yalnız sistem fontları; pakette font, görüntü ya da kare dizisi yok.

## 2. v0.1 kapsamı

### 2.1 Eylemler (20)
Yarılar (sol/sağ/üst/alt), çeyrekler (4), üçte birler (ilk/orta/son), üçte ikiler (ilk/orta/son),
Maximize, Almost Maximize (varsayılan %90, ortalı), Center (boyut korunur), Restore (snap öncesi
çerçeve), Next/Previous Display.
- **Boyut döngüsü:** aynı yarı eylemi aynı pencerede, pencere hâlâ son hedefteyken tekrarlanırsa
  1/2 → 2/3 → 1/3 → 1/2 (kapatılabilir). Tolerans: her kenarda max(16 pt, kullanılabilir genişliğin %2'si).
- **Dikey ekran:** üçte birler/üçte ikiler satır olur.
- **Next/Previous Display:** pencere son eylemin hedefindeyse aynı eylem (aynı döngü adımı) yeni
  ekranda yeniden uygulanır; değilse göreli konum ve oransal boyut korunur. Ekran sırası x, sonra y.
- **Gap:** dış (ekran kenarı) ve iç (komşu pencereler arası) ayrı, 0–24 pt (çekirdek 0–64 kabul eder).

### 2.2 Varsayılan kısayollar
Classic set: ⌃⌥ + ←→↑↓ (yarılar), U I J K (çeyrekler), D F G (üçte birler), E R T (üçte ikiler),
↩ Maximize, ⇧↩ Almost Maximize, C Center, ⌫ Restore, ⌃⌥⌘ ←/→ ekranlar.
Alternate set (VoiceOver kullanıcıları için; ⌃⌥ VO tuşudur ve VO+⌘ komutları da vardır → ⌃ ile ⌥ hiç
birlikte kullanılmaz): tiling ⌃⇧⌘ + aynı tuşlar, ekranlar ⌃⇧⌘ [ / ], almost maximize ⌃⇧⌘M.
Option-Command set (0.4.0; Spectacle'ın yaygınlaştırdığı, Tiles'ın koruduğu düzen): ⌥⌘ + ←→↑↓ ve
U I J K, ⌥⌘F Maximize, ⇧⌥⌘↩ Almost Maximize, ⌥⌘C Center, ⌥⌘Y Restore, ⇧⌥⌘ D F G üçte birler (⌥⌘D
Dock'undur), ⌃⌘ ←/↑/→ üçte ikiler, ekranlar ⌃⌥⌘ ←/→. Tiles ya da Spectacle kuruluysa ve kısayollara
dokunulmamışsa onboarding bu setle başlar (VoiceOver'ın Alternate'i önceliklidir). Classic
aktifken VoiceOver açılırsa ⌃⌥ kayıtları askıya alınır (VO kapanınca geri gelir; "Keep ⌃⌥ with
VoiceOver" ile kapatılabilir). Kayıt Carbon `RegisterEventHotKey` (izin gerektirmez, virtual key
code = fiziksel konum). Yalnız-⌥ / ⌥⇧ kombinasyonlarında recorder uyarır (macOS 15.0–15.1 bunları
reddediyordu, 15.2'de gevşetildi — COMPETITORS.md); gerçek sonuç kayıt durumundan gösterilir.
Kayıt hatası (başka uygulama almış) kullanıcıya satır bazında gösterilir; yeni kaydedilen bir kısayol
reddedilirse önceki geri konur (çalışan kısayol kaybedilmez). Recorder değiştiricisiz / yalnız-⇧
(F-tuşları hariç), yalnız-⌘ / ⇧⌘ ve macOS'un etkin sistem kısayollarını (HIToolbox
`CopySymbolicHotKeys`, dlsym ile; yoksa yalnız sabit liste) nedeniyle reddeder. Tablo değişimleri
(Swap, set değişimi) iki geçişte bağlanır. Gösterilen tuş adı o anki klavye düzeninden gelir
(UCKeyTranslate), saklanan kimlik sanal tuş kodudur (DESIGN §8).

### 2.3 Sürükle-bırak
- Bölgeler (ekran başına): sol, sağ, üst, 4 köşe, alt kenar 3 segment. Varsayılan eşleme:
  sol→Left Half, sağ→Right Half, üst→Maximize, köşeler→çeyrekler, alt segmentler→üçte birler.
  Alternatif harita (varsayılan ⇧ basılıyken; ⌥ macOS 15+ "Hold ⌥ while dragging to tile" ile çakışır): sol→First Third, sağ→Last Third, üst→Top Half,
  alt segmentler→üçte ikiler. Her bölge her iki haritada kullanıcı tarafından atanabilir (ZoneMap).
- Hassasiyet: kenar bandı 3/5/10 pt, köşe uzunluğu 20/32/48 pt (Tight/Normal/Wide; varsayılan Normal).
- Ekranlar arası paylaşılan kenarlarda bölge yok (varsayılan; Dragging › "Snap where displays meet").
  Paylaşım imlecin bulunduğu noktada değerlendirilir: kenarın komşu ekranla devam etmeyen kısmı (ör. dizüstünün
  yanından taşan harici ekran alt kenarı) bölge olarak çalışır.
- Önizleme overlay'i (DESIGN §9) gösterilen dikdörtgen = uygulanacak dikdörtgen. Tek önizleme türü
  vardır (çizgi; v1'deki Dots/Outline seçimi kalktı).
- **Snap-back:** Nokta'nın snap'lediği pencere sürüklenince snap öncesi boyutuna döner (imlecin
  pencere içindeki göreli x konumu korunur; kapatılabilir). Yalnız gerçek sürüklemede: imleç basıştan
  > 4 pt uzaklaşmadıkça (tıklama, başlık çubuğu çift tıkı/zoom, titreme) tetiklenmez; Moved bildiriminden
  30 ms sonra pencerenin boyutu hâlâ aynıysa sürükleme sayılır — sol/üst kenardan boyutlandırma (boyut
  değişir ya da araya Resized bildirimi girer) snap-back/önizleme başlatmaz. Menü çubuğuna dayalı, yukarı
  çekilemeyen pencere de böylece üst bölgeye sürüklenebilir — yana en az 1 pt kaydığı sürece (tamamen dikey
  sürüklemede pencere hiç hareket etmez, AX'te görünür bir jest yoktur: ⌃⌥↩ kullanılır); basış anı çerçevesi
  kıskaç dikkate alınarak tahmin edilir (Restore doğru yere döner).

### 2.4 Kurallar
Uygulama istisna listesi (bundle id, büyük/küçük harf duyarsız, en fazla 64): listedeki uygulama öndeyken
Nokta'nın kısayolları **kayıttan çıkarılır** (Carbon kısayolları globaldir; aksi halde uygulamanın kendi
kısayolunu yutardı) ve sürükleme snap yapmaz. Menüden "Ignore “App”" ile hızlı ekleme; liste Settings › General
› Ignored apps'te.

### 2.5 Kabuk
Menü bar (üç durumlu ikon + eylemler + Pause + Ignore + Settings + Quit; durum yuvası yalnız gerekince),
Settings (4 sekme: General — Ignored apps dahil —, Shortcuts, Dragging, About), Onboarding (3 ekran,
animasyonlu; izin akışı otomatik algılama), flash + "when needed" etiketleri, ses (varsayılan kapalı) ve
haptik (varsayılan açık), login item (`SMAppService`), macOS yerleşik tiling çakışması tespiti (salt okuma)
ve uyarı kartı.
- **Menü bar ikonu:** 18 pt template, kodla çizilir; durumlar şekille ayrılır (Active: çerçeve + dolu yarı +
  dolu nokta · Paused: çerçeve + halka nokta · Needs permission: çerçeve + çapraz çizgi). Hiçbir zaman
  kırmızı ya da hareketli değildir.
- **Menü durum yuvası:** her şey yolundayken menüde durum satırı yoktur (ikon durumu gösterir). Gerekince tek
  öğe çıkar, öncelik sırasıyla: `Allow Accessibility…` (R3 kırmızı nokta; onboarding ekran 2) · `Finish
  Setup…` · `Shortcuts paused for VoiceOver…` · `Drag snapping unavailable` · `Nokta stopped…`. Ölçülen
  sayılar menüde değil, About'tadır; `menuNeedsUpdate` ölçüm yapmaz, yalnız sağlık kontrolü ve yeniden kurma.
- **Onboarding (3 ekran):** Welcome (sürükle-oturt demosu; nokta `nokta.` yazı markasına uçar) · Access (izin
  anahtarı demosu, ≤ 3 döngü; izin gelince `Access granted.`) · Try (tuş demosu, ≤ 3 döngü, sonra ayna modu).
  Üstteki sahne kalıcıdır, yalnız içeriği değişir; Reduce Motion'da sahneler statik poz gösterir.

### 2.5.1 İlkeler
- **Gizli tercih yok:** her ayar Settings'te; terminal-only ayar yok.
- **v2'de kalkan iki tercih:** önizleme stili (Dots/Outline; tek önizleme kaldı, `previewStyle` anahtarı artık
  okunmaz, Reset All onu temizler) ve "Show shortcuts in menu" (menü her zaman kısayolları gösterir).
- **Sade metin:** UI İngilizce, yalnız sistem fontları; yardım satırı en fazla bir kısa satır; toplam görünür
  metin ≤ 600 kelime (DESIGN §10.2).
- **Space'ler arası taşıma desteklenmez** (public API yok; private API kullanmama kararı). Belgelenmiş sınırlama.
- macOS yerleşik tiling ve Stage Manager açıksa kullanıcı uyarılır (salt okuma), Apple ayarlarına yazılmaz.

### 2.6 v0.1 dışında (bilinçli)
Grid paneli, özel boyutlar, kayıtlı düzenler/workspace, uygulama başına kısmi kural modları, Stage
Manager alanı hesabı, CLI/URL scheme, Rectangle ayar içe aktarma, Türkçe yerelleştirme, notarize
dağıtım, x86_64 (universal build script'te opsiyonel).

## 3. Mimari

```
┌──────────────────────── Snapline.app (tek süreç, main thread) ────────────────────────┐
│ Swift/AppKit kabuk (app/Sources)                                                    │
│  AppController ── StatusMenu · Settings · Onboarding · SnapOverlay(+etiket) · Feedback│
│       │  NoktaEngine.swift (C ABI sarmalayıcı) · Preferences (UserDefaults)          │
│       ▼  nokta.h (C ABI, ABI v1)                                                     │
│ Zig çekirdek libnokta.a (core/src)                                                   │
│  root.zig (export) ─ Engine (durum makinesi, saf) ─ layout · zones · geometry · rules│
│       │ WindowSystem vtable                                                          │
│  platform/: ax_window_system · hotkeys (Carbon) · event_tap (listen-only)            │
│             observer (AXObserver, ön plan uygulaması) · display_watch (CGDisplay)    │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- **Tek thread:** Carbon hotkey'ler, event tap, AXObserver ve display callback'leri main run loop'ta;
  çekirdek kilitsiz. AX çağrılarında global messaging timeout 0.5 s (asılı uygulama riski §8).
- **Koordinatlar:** çekirdekte her şey CG global (sol-üst, y aşağı, point). Kabuk yalnız kendi
  pencereleri için AppKit'e çevirir (`Screens.appKitRect(fromCG:)`).
- **Ekran geometrisi:** ekran listesi ve sınırları çekirdekte `CGGetActiveDisplayList` + `CGDisplayBounds`.
  Kullanılabilir alan (menü bar + Dock hariç): kabuk `NSScreen.visibleFrame`'i CG'ye çevirip menü barlı
  ekranlarda üst kenarı +1 pt indirerek `nk_core_set_display_usable` ile verir (ölçüldü: AppKit pencereyi
  menü bar altı + 1'e iter; 30 pt menü barda y=31, çentikli 32 pt built-in'de y=1113). Yedek:
  `HIWindowGetAvailablePositioningBounds` — ana ekranın menü bar yüksekliğini her ekrana uyguladığı için
  çentikli ekranda 2 pt hatalı (ölçüldü), yalnız override yoksa kullanılır. Değerler önbelleklenir; CG
  display reconfiguration callback'i ve kabuğun `didChangeScreenParameters`/uyanma bildirimleri yeniler.
- **Pencere bulma:** kısayolda ön plan uygulamasının pid'i (NSWorkspace'ten kabuk iletir) →
  `AXUIElementCreateApplication(pid)` → `AXFocusedWindow` (yedek: main window, ilk pencere); izin
  kaldırılmışsa `NK_ERR_NOT_TRUSTED`, uygulama yanıt vermezse `NK_ERR_AX` (NO WINDOW değil). Sürüklemede
  ön plan uygulamasına kurulu AXObserver'ın `kAXWindowMovedNotification`'ı; yalnız imlecin altındaki
  pencereninki sayılır (sheet/panel/diğer pencereler değil). Observer kurulamamışsa 4 pt eşikten sonra
  `AXUIElementCopyElementAtPosition` ile yedek hit-test (30 ms aralık, en fazla 10 deneme); observer ön
  plan uygulamasına bağlıyken ve ⌘ basılı değilken yedek çalışmaz (metin seçimi/kaydırma hedef uygulamaya
  AX yükü bindirmez; ⌘ ile arka plan pencere sürüklemesi yedekle çalışır; bedeli: Moved bildirimi
  göndermeyen bir uygulama varsa onda sürükleme snap'lenmez — cihazda doğrulanacak). Observer kaydı uygulama başına 0.25 s
  zaman aşımıyla yapılır (asılı uygulamaya geçiş ana thread'i en fazla 0.25 s bekletir).
- **Çerçeve uygulama:** aynı ekranda position→size, ekranlar arası size→position→size. Gecikme ölçümü
  son setter dönüşünde biter; ardından **tek** position+size okuması yapılır (metriğe dahil değil):
  konum değişimi istendiği hâlde okuma setter öncesi çerçeveye eşitse uygulama değişikliği asenkron
  uyguluyordur (bayat okuma; min boyut konumu engellemez) → hedef esas alınır, hiçbir şey geri yazılmaz
  (sürükleme bırakmasında setter öncesi çerçeve bir kez okunur); pencere döşemeden **büyük** çıktıysa (min boyut) ya da boyutu
  reddettiyse (sabit boyut) döşemenin ait olduğu kenara hizalanır (sağ yarı → sağ kenar, orta üçte bir →
  ortalı; tek ek **konum** yazımı) ve olay `NK_EVENT_FLAG_FRAME_DIFFERS` (`Can't get smaller`) ya da
  `NK_EVENT_FLAG_SIZE_REFUSED` (`Can't resize`) taşır — üç kapalı rakibin de yaptığı davranış
  (COMPETITOR-DEEP.md); birkaç pt küçük kalma (boyut artımı, ör. Terminal hücre ızgarası) bayraksız
  gerçek çerçeve olarak bildirilir. Bellek ortaya çıkan çerçeveyi saklar. `AXEnhancedUserInterface` açıksa işlem başına bir kez kapatılır ve geri açılır
  (Chromium için yeniden açmanın maliyeti bilinen risk: §8).
- **Engine sözleşmesi:** `core/src/engine.zig` başlığı (perform, drag pipeline, memory LRU 32,
  latency halkası 128, programatik eko bastırma 150 ms).
- **C ABI:** `core/include/nokta.h` tek sözleşme; struct düzenleri Zig `comptime` + C `_Static_assert`
  ile iki taraflı test edilir (`zig build test`).
- **Build:** `zig build` (lib) · `zig build test` · `zig build app` (swiftc + bundle + imza) ·
  `zig build bench` · `zig build integrity`. Xcode projesi yok.

## 4. İzinler ve imza
- Yalnız **Accessibility** (AX + listen-only mouse tap). Input Monitoring istenmez: tap yalnız fare
  olaylarını dinler (flagsChanged bile yok; modifier'lar fare olayının bayraklarından okunur), kısayollar
  Carbon. Screen Recording istenmez (pencere görüntüsü alınmaz).
- Geliştirme imzası: ayrı `nokta-dev.keychain-db` içindeki self-signed "Nokta Local Dev Signing"
  sertifikası; designated requirement `identifier "com.htahaozlu.nokta" and certificate root = H"cad4…"`
  build'ler arasında sabit → Accessibility izni her build'de sıfırlanmaz. Ad-hoc imza yalnız uyarıyla.
- **İmza güvenliği (review O3):** TCC izni DR'yi sağlayan koda verir; bu anahtarı kullanabilen, kullanıcı
  olarak çalışan herhangi bir program kendini Nokta diye imzalayıp Accessibility'yi devralabilir. Bu her
  geliştirici imza kimliği için geçerlidir, ama anahtar diskte **düz metin** dururken kalıcı olarak
  kopyalanabilir. Bu yüzden `setup-signing.sh --create` anahtarı keychain'e **dışa aktarılamaz** alır ve
  `key.pem`/`id.p12`'yi siler; keychain uykuda ve 1 saat sonra kilitlenir (build parola dosyasıyla açar).
  Bu kurallardan önce oluşturulmuş kimlik için `--harden` (sertifika ve DR aynı kalır), geliştirme
  bitince `--remove` + System Settings'ten Nokta'nın Accessibility kaydını kaldırma. Dağıtım (roadmap)
  Developer ID + notarization ile; o zaman DR Apple köküne ve team ID'ye bağlanır.
- Release (roadmap): Developer ID + notarization; entitlement yine yok.

## 5. Performans hedefleri ve ölçüm tanımları
| Hedef | Metrik | Ölçüm |
|---|---|---|
| Idle CPU ~%0 | `top` %CPU ortalaması + idle wakeups, 60 s, 5 s örnek | `scripts/bench.sh` (headless `--bench-idle`, kısayolsuz) |
| RSS < 15 MB (AppKit ile ulaşılamaz, bkz. §8) → birincil: footprint ≤ 12 MB | `ps -o rss` + `phys_footprint` (top MEM) birlikte raporlanır; boş AppKit süreci referans olarak ölçülür | aynı |
| Binary < 3 MB | `Contents/MacOS/Snapline` boyutu (arm64; universal ayrıca) | build çıktısı |
| Kısayol→taşınma p95 < 16 ms | **Nokta gecikmesi:** tetikleme anı → son AX setter dönüşü (çekirdek ölçer). Kernel→Carbon teslimi ve ekran yenileme dahil değil | harness: kendi test penceresine `nk_core_perform_pid` × 300, ayrıca çekirdek istatistiği |
| Soğuk açılış < 150 ms | spawn → `applicationDidFinishLaunching` sonu + çekirdek başladı (`NOKTA_READY`) | `--bench-startup` × 20; build sonrası ilk koşu ayrıca |

Uçtan uca (ekranda görünme) gecikme hedef uygulamanın AX yanıtına bağlıdır (Electron/Java'da yüksek);
About sekmesi bunu olduğu gibi gösterir. Rakiplerle aynı senaryo: Tiles (kullanıcının açık süreci, pasif)
ve rakip binary'lerin statik ölçüleri; rakipleri çalıştırmak canlı sistem kuralı gereği yapılmaz
(BENCHMARKS.md'de yazılı).

## 6. Gizlilik ve integrity
- Kod ağ API'si içermez (`socket/connect/getaddrinfo/CFNetwork/NSURLSession/nw_*` import'u yok);
  her release'de `scripts/integrity.sh` (REA) bunu, entitlement'ları, bağlı framework'leri ve private
  framework yokluğunu doğrular → `docs/INTEGRITY.md`. İhlal = release yok.
- Yazılan dosyalar: `~/Library/Preferences/com.htahaozlu.nokta.plist`, ses önbelleği
  `~/Library/Caches/com.htahaozlu.nokta/sounds/`. Başka hiçbir şey.
- Apple'ın ayarlarına ve TCC'ye yazılmaz (yalnız salt okuma tespiti).

## 7. Geliştirme ve test güvenliği (canlı sistem)
Kullanıcının gerçek masaüstünde çalışılır; terminalin Accessibility izni vardır.
- Otomatik testler yalnızca saf modüller + mock (`zig build test`).
- AX setter'ları yalnızca harness'ın kendi test penceresine (`NOKTA-BENCH-`/`NOKTA-SMOKE-` başlık
  doğrulaması) uygulanır. Ön plan/odak penceresine setter çağıran test yok.
- Global kısayol kaydı, `CGEventPost`, sentetik girdi testte yok. Kısayol ve sürükle-bırak uçtan uca
  doğrulaması kullanıcı tarafından manuel checklist ile yapılır (`docs/TESTING.md`).
- `--bench-startup` / `--bench-idle` / `--bench-used` modları kısayol kaydetmez, olay tap'i/observer kurmaz
  (drag snap kapalı), pencere açmaz ve çekirdeğe hiçbir pencereyi taşıtmaz. Menü çubuğu öğesi açılış ve
  bellek ölçümü gerçek kurulumu yansıtsın diye oluşturulur, ama her zaman **Paused** durumunu gösterir.
  `--bench-used` ayrıca açılıştan 300 ms sonra ana ekranın sol alt köşesinde 200×120'lik bir alanda overlay'in
  dört geçişini sentetik olayla çalıştırır: O1 (sürükleme girişi), O4 (bırakma), O5 (klavye flash'ı) ve O7
  (etiket plakası). Çekirdek devrede değildir ve hiçbir pencere taşınmaz (tıklamayı geçiren overlay, açılıştan
  ~2 s içinde söner). Böylece overlay paneli, katman ağacı ve plakanın metni oluşmuş hâldeki "kullanım sonrası
  idle" ölçülebilir; event tap/observer bu ölçüme dahil değildir.
- Cihaz doğrulaması için iki ek bench modu daha var; ikisi de aynı güvenceleri taşır (kısayol yok, drag snap
  yok, hiçbir pencere taşınmaz):
  - `--bench-menu`: açılıştan 6 s sonra Nokta kendi menüsünü bir kez açar ve 1.5 s sonra kapatır; ilk menü
    açılışının bıraktığı bellek ölçülür.
  - `--bench-preview <yüzey> [--close-after <s>]`: bir onboarding ekranını (`onboarding-1`…`-3`,
    `onboarding-2-waiting`, `onboarding-2-grant`) ya da Settings sekmesini (`settings-general` …) gerçek
    ekranda gösterir. Tercihler geçici `com.htahaozlu.nokta.bench-preview` alanındadır. Pencere numarası
    `NOKTA_BENCH_EVENT window <n>` ile bildirilir (ekran görüntüsü için; `scripts/a11y-audit.sh` süreç kimliğiyle çalışır).
- Bench modlarında menüde yalnız Quit etkindir; eylemler, Pause/Resume, Ignore ve Settings… kapalıdır ve
  `AppController` kısayol bağlamayı, `setPaused`'ı, `perform`'u ve (yalnız `--bench-preview` dışında) Settings ve onboarding pencerelerini açmayı reddeder; hiçbir bench modu login item'a, izin istemine ya da gerçek tercih alanına dokunmaz. İsteğe bağlı menü aşaması
  (`NOKTA_BENCH_MENU=1 scripts/bench.sh`) kullanıcıdan menüyü bir kez açıp kapatmasını ister ve öncesi/sonrası
  footprint'i ölçer; bu güvence sayesinde menüde tıklanan hiçbir şey bir pencereye dokunmaz.

### 7.1 UI snapshot aracı
`scripts/snapshot.sh [dizin]` (varsayılan `tools/snapshot/out`, git'e girmez) arayüzü hiçbir pencere açmadan PNG
ve GIF'e çizer; tasarım incelemesi ve görsel gerileme kontrolü içindir.
- **İnert çekirdek:** araç, kabuğun kaynaklarını (`App/main.swift` hariç) `zig build -Dinert=true` ile üretilen
  ayrı `libnokta-inert.a`'ya linkler (`core/src/inert.zig`). `-Dinert=true` iken `zig build app|bench|integrity`
  bilinçli olarak hata verir; `scripts/build-app.sh` linkten sonra ikilide gerçek çekirdeğin
  (`_AXUIElementCreateApplication`, `_CGEventTapCreate`) olduğunu ve inert işaretinin (`nk_inert_core`)
  olmadığını doğrular. İnert çekirdek imzalı uygulamaya hiçbir yoldan giremez. Bu çekirdek aynı C ABI'yi dışa verir ama Accessibility, kısayol,
  event tap, AXObserver ya da ekran çağrısı yapmaz; `nk_ax_is_trusted` yalnız `NOKTA_SNAPSHOT_TRUSTED`
  ortam değişkenini okur (izinli ve izinsiz durum çizilebilsin diye). İkili, `nm -u` ile canlı platform
  sembolü içermediği doğrulanmadan çalıştırılmaz.
- **Pencere açmaz:** hiçbir pencere, panel ya da status item ekrana alınmaz; `orderFront*`, `NSApp.run()` ve
  `NSApp.activate` kullanılmaz; uygulamanın açılış yolu (`AppController` delege olarak, çekirdeğin başlatılması)
  çalışmaz. Nokta'nın kullanıcı tercihlerine (`com.htahaozlu.nokta`) ve sistem ayarlarına dokunulmaz; menü
  sahneleri tercihleri geçici bir defaults suite'inde tutar (yalnız kayıtlı değerler, hiçbir şey yazılmaz).
- **Önce SelfTest:** `pose(at:)` sözleşmesi (DESIGN §5.2 madde 9) denetlenir; bir hata sıfırdan farklı çıkış
  koduyla durdurur.
- **Çizdikleri** (açık ve koyu; izinli ve izinsiz): 4 Settings sekmesi, 3 onboarding ekranı, her overlay
  timeline'ının storyboard kareleri ve sahne GIF'leri (yalnız inceleme için, pakete girmez) ile Reduce Motion
  pozları, menü bar ikonları (1x/2x), eylem glifleri ve durum menüsü: `menu.txt` yapı dökümü (tüm durumlar) ve
  `menu-<durum>-<light|dark>.png` sahte menü paneli (healthy, needs-permission, paused, voiceover).

## 8. Riskler
| Risk | Etki | Azaltım |
|---|---|---|
| Asılı uygulama main thread'i 0.5 s'ye kadar bloklar | kısayol/sürükleme gecikir; tap aynı thread'de | tap listen-only (sistem girdisini bekletmez, yabai #2829'daki aktif tap deseninden farklı); timeout 0.5 s; v0.2: tap + AX için ayrı thread/uygulama başına kuyruk |
| Chromium: AXEUI geri açma ve AX gözlemi web a11y'yi pahalılaştırabilir | Chrome yavaşlar | işlem başına tek toggle; min-boyut hizalaması AXEUI'ye dokunmayan tek konum yazımı; observer ön plandayken yedek hit-test hiç çalışmaz (metin seçimi AX yükü yok); v0.2: Chromium ailesi için "AXEUI kapalı bırak" politikası (Speedometer ile ölçülecek) |
| macOS yerleşik tiling ile çift tepki | kafa karışıklığı | salt okuma tespiti + uyarı kartı |
| Stage Manager sürükle-bırakı ezer | snap tutmaz | belgelenmiş sınırlama; v0.2 |
| `HIWindowGetAvailablePositioningBounds` header'da yok | gelecekte kaldırılabilir | hata dönerse CGDisplayBounds yedeği; v0.2 kabuk override ABI |
| Carbon hotkey ⌃⌥ VoiceOver çakışması | VO kullanıcıları | Alternate set + onboarding önerisi |
| AppKit taban belleği 15 MB RSS'i zorlar | **ölçüldü: hedef AppKit ile ulaşılamaz** — penceresiz boş bir AppKit süreci bu makinede RSS 31.9 MB / footprint 7.0 MB (boş C süreci 1.3 MB); RSS paylaşılan dyld-cache sayfalarını sayar | birincil bellek metriği `phys_footprint` (hedef ≤ 12 MB); RSS yine raporlanır. v0.2 seçeneği: AppKit'siz çekirdek daemon'u (Zig, kısayol/tap/AX) + talep üzerine açılan UI süreci (menü bar ikonu olmadan) |
| Çentikli built-in ekranda tam genişlik maximize aralıklı olarak 1512 → 1429'a kesiliyor (AppKit, setter anında; hedef genişlik = ekran genişliği iken, geçmişe bağlı) | pencere tam genişliği doldurmaz | engine read-back gerçek çerçeveyi bildirir ve flash onu çizer (pencere küçük kaldığı için etiket yok; bench'te doğruluk kontrolü yakalar); kök neden v0.2 (ön plan test penceresiyle yeniden ölçülecek) |
| Haptik arka planda çalışmayabilir | işlevsiz ayar | cihaz testi; çalışmıyorsa kaldır |

## 9. Roadmap
- **v0.2:** grid paneli (Tiles parity), özel boyutlar/yüzdeler, kısmi kural modları (yalnız kısayol /
  yalnız sürükleme), uygulama başına AX kuyruğu, Chromium politikası, Stage Manager alanı, bölge
  histerezisi, AppKit visibleFrame override ABI, Rectangle ayar içe aktarma, URL scheme
  (`nokta://action/left-half`), Türkçe yerelleştirme, Developer ID + notarization, universal build.
- **v0.3:** kayıtlı düzenler (ekran yapılandırmasına göre otomatik), uyku/uyanma ve ekran değişiminde
  geri yükleme, CLI, Shortcuts.app eylemleri.
- **Sürekli:** her release'de BENCHMARKS + INTEGRITY yeniden üretilir.
