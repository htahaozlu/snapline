# Nokta — Tasarım (uzlaşılmış v2)

> **Neden v2:** kullanıcı v0.1'i gördükten sonra şunu dedi: nokta tasarımı güzel ama anlaşılmıyor, bazı
> yerlerde fazla yazı var, çok daha sade olmalı. "Nothing dokunuşu" ile kastettiği nokta matrisi değil,
> çizgi dışı bir özgünlüktü. Onboarding'de, özellikle izin adımında animasyon istedi: sürükleme, düzgün
> ekran geçişi, kısayol gösterimi. Performansta da disk ve sistem kullanımında "sanki yok gibi" olmasını
> istedi.
>
> **Kaynaklar:** iki bağımsız tasarım taslağı (bu repoda yayımlanmaz). İkisi bağımsız
> yazıldı ve ikisi de v0.1 render'larına (`tools/snapshot`) bakarak hazırlandı. Ortak kararlar doğrudan
> alındı; çatışmalar §13'teki tabloda gerekçesiyle çözüldü. Bu belgenin vermediği ayrıntılarda (ölçü,
> kare tablosu) burada adı geçen öneri bölümü bağlayıcıdır. v1 belge git geçmişindedir.
>
> **Kapsam:** Özellikler SPEC'teki gibidir. v2 görünüşü, metni ve hareketi değiştirir. İki tercih
> kalkar: önizleme stili (Dots/Outline) tek önizleme kaldığı için, "Show shortcuts in menu" ise menü
> zaten kısayol kartı olduğu için. UI metinleri İngilizcedir. **P** etiketi cihazda doğrulanacak
> değerleri gösterir.

## 1. Sert kısıtlar
- Yalnız AppKit + Core Animation. SwiftUI, WebKit, AVAudioEngine, Metal.framework ve Lottie yok (`otool -L` kontrolü; Swift'in otomatik bağladığı zayıf `libswiftMetal.dylib` bir framework bağlantısı değildir).
- **Yalnız sistem fontları:** SF Pro, SF Mono, SF Symbols. Pakette font dosyası yok; Doto ve OFL lisans dosyası silinir.
- Pakette görüntü, video, GIF ya da bitmap kare dizisi yok. Her şey kodla çizilir; uygulama ikonu tek istisnadır (`.icns`).
- Idle'da timer ya da animasyon çalışmaz. Tek istisna, onboarding izin ekranı ekrandayken (başka bir pencerenin altında kalsa bile; §11) çalışan 1 Hz yedek kontroldür.
- `phys_footprint` idle'da ≤ 12 MB, kullanım sonrasında da ≤ 12 MB (`--bench-used`). Paket ≤ 950 kB (ilk tahmin 0.8 MB idi; §16).
- Hiçbir markanın asset'i kullanılmaz: Nothing'in NType fontu, glifleri ve logosu, rakiplerin ikon ve metinleri. İlham serbesttir, kopya yasaktır.
- Ağ yok, telemetri yok, güncelleme kontrolü yok.

## 2. Konsept ve ilkeler

**"Çizgi gösterir, nokta bitirir."**
- **Çizgi.** Pencerenin oturacağı çerçeve, dokunduğun kenardan başlayıp iki yöne doğru kendini çizer (160 ms). Önizlemeyi "çizen" bir pencere yöneticisi yok; dikdörtgenin kendisi ise anında okunur.
- **Nokta.** Türkçede "nokta" cümle sonu da demek. İş bitince tek bir kırmızı nokta konur: pencere oturdu, izin verildi. Yani "yerine oturdu, nokta." Nokta artık doku değil; yalnız bitiş, dikkat ve kayıt sinyalidir.
- **Marka:**
  - İşaret `▮▯.`: yarısı dolu bir pencere, noktası çerçevenin dışında. Kelimenin tam anlamıyla "çizgi dışında".
  - Yazı markası: küçük harf `nokta.`, noktası kırmızı.
- **Nothing'den kalan:** monokrom, tek kırmızı, teknik çizim hissi, ham dürüstlük (About'ta ölçülen sayılar).
- **Giden:** nokta kafesi, Doto, nokta glifleri, DotMeter, metrikli menü, açıklama paragrafları.

**İlkeler:**
1. **Pencere kahramandır.** Her eylemin görsel izi ≤ 260 ms sürer; etiket gerekirse ≤ 950 ms, engellendi etiketi ≥ 2 s. Sonra ekranda iz kalmaz.
2. **Önizleme söz verir.** Overlay'in gösterdiği dikdörtgen, çekirdeğin yazacağı dikdörtgenle aynı fonksiyondan gelir (`layout.frameFor`).
3. **Tek dil: çizgi + nokta.** Gradient, glow, blur ve gölge yok. Doku yok.
4. **Monokrom + tek kırmızı.** Kırmızının yalnız üç anlamı var: *bitti*, *sana ihtiyaç var*, *dinliyorum*. Bir yüzeyde aynı anda en fazla bir kırmızı öğe olur. Durum asla yalnız renkle verilmez.
5. **Sistem sistemdir.** Standart kontroller kullanılır. Özel kontrol yalnız dört tane: ShortcutRecorder, ZoneMap, Stage (onboarding sahnesi) ve LineMeter.
6. **Göster, yazma.** Yardım satırı yalnız bir kararı değiştiriyorsa vardır, o da en fazla bir kısa satırdır. Hiçbir paragraf iki kısa satırı geçmez. Ayrıntı tooltip'e gider.
7. **İşi göster, iddia etme.** UI'daki her sayı o anda ölçülür; "hafif", "hızlı" gibi sıfat yok.
8. **Varsayılan sessiz.** Ses kapalı, haptik açık, etiket yalnız gerektiğinde.
9. **Gizli tercih yok.** Koşullu satır yalnız alakasız olduğu sürece görünmez; örneğin VoiceOver satırı VoiceOver açıkken her zaman görünür.

## 3. Anti-pattern'ler (yasak)
- **Kırmızı:**
  - metin, buton ya da dolgu olarak kullanmak (nokta dışında),
  - bir yüzeyde iki kırmızı öğe,
  - kırmızının yanıp sönmesi.
- **Hareket:**
  - sonsuz animasyon; bir demoyu 3 turdan fazla döndürmek;
  - animasyon için `Timer`, `CADisplayLink`, `CVDisplayLink`, `DispatchSourceTimer` ya da `asyncAfter` zinciri;
  - gizli ya da örtülü bir yüzeyde çalışan animasyon;
  - pencereyi AX ile adım adım "animasyonlu" taşımak. Pencere tek adımda oturur; hareketi overlay taşır.
- **Çizim ve asset:**
  - nokta başına bir CALayer; replicator kafesi; tam ekran `draw(_:)`;
  - tam ekran bitmap ya da strip;
  - pakette font, GIF, video, Lottie ya da PNG kare dizisi;
  - sistem imlecini ya da Apple arayüzünü bire bir kopyalayan illüstrasyon (sahnedeki imleç Nokta'nın kendi ok yoludur).
- **Davranış ve metin:**
  - her snap'te HUD, konfeti ya da rozet; nag, upsell, puanla ekranı;
  - sahte ya da sabit metrik;
  - grup başlığıyla doldurulmuş form;
  - iki satırdan uzun yardım metni.

## 4. Token'lar

### 4.1 Renk
Standart pencerelerde sistem semantik renkleri kullanılır. Bu tablo yalnız özel yüzeyler içindir (overlay, Stage, ZoneMap, LineMeter, plaka, menü glifleri). Değerler `bestMatch` ile çözülür (v1 mekanizması). IC = Increase Contrast, RT = Reduce Transparency.

| Token | Light | Dark | IC Light | IC Dark | Kullanım |
|---|---|---|---|---|---|
| `ink` | `#111113` | `#F5F5F3` | `#000000` | `#FFFFFF` | çizgi, dolgu, özel metin |
| `ink.2` | ink α .62 | α .62 | α .80 | α .80 | ikincil çizgi ve metin |
| `ink.3` | ink α .28 | α .30 | α .55 | α .60 | pasif çizgi (ZoneMap, sahne çerçeveleri) |
| `ink.wash` | ink α .06 | α .08 | α .12 | α .14 | sahne içi dolgular, basılı tuş |
| `paper` | `#F7F7F5` | `#0B0B0C` | `#FFFFFF` | `#000000` | onboarding zemini |
| `paper.raised` | `#FFFFFF` | `#161618` | + 1 pt ink kenar | + 1 pt ink kenar | sahne, kartlar |
| `hairline` | ink α .12 | α .14 | α .45 | α .45 | sahne kenarı |
| `red` | `#E0301E` | `#FF4438` | `#B8200F` | `#FF6A5C` | yalnız §4.2 listesi |
| `ov.scrim` | `#FFF` α .28 | `#000` α .32 | α .45 | α .45 | önizleme dolgusu; RT .80 |
| `ov.line` | ink α .92, 2 pt | aynı | α 1, 3 pt | α 1, 3 pt | önizleme çizgisi |
| `ov.halo` | paper tonu α .55, çizginin dışında 1 pt | aynı | α .90 | α .90 | keyfi zeminde çizgi ayrımı; RT .95 |
| `plate.fill` / `plate.text` | ink / paper.raised | aynı | + 1 pt paper α 1 kenar | aynı | etiket plakası (ters renk) |

### 4.2 Kırmızının kapalı listesi
Bir yüzeyde aynı anda en fazla bir kırmızı öğe olur. Menü bar ikonu hiçbir zaman kırmızı değildir.

| # | Yer | Boyut | Anlam |
|---|---|---|---|
| R1 | Overlay'in commit ve flash noktası; onboarding sahne A ve C'deki ölçekli kopyası | Ø 8 (sahnede Ø 6–7) | bitti, burada |
| R2 | ShortcutRecorder kayıt noktası | Ø 6 | dinliyorum |
| R3 | Menüdeki durum yuvası: `Allow Accessibility…` | Ø 8 | sana ihtiyaç var |
| R4 | Onboarding `Waiting…` noktası. İzin gelince başlığın noktası olur, 1.8 s sonra ink'e döner. | Ø 8 | ihtiyaç var, sonra bitti |
| R5 | About'taki LineMeter'ın 12 MB tikini aşan kısmı | çizgi | dikkat |
| R6 | Marka: uygulama ikonunun noktası; `nokta.` yazı markasının noktası (onboarding ekran 1, About) | metne göre | kimlik |

Ekran 1'deki çakışma şöyle çözülür. Demo noktası (R1) yazı markasına uçar ve R6 olur; uçuş bitene kadar yazı markasında nokta yoktur. Bu yüzden ekranda hep tek kırmızı vardır.

### 4.3 Tipografi
Yalnız sistem fontları kullanılır, kern yoktur. Kesirler gerçek glifle yazılır (`½ ⅓ ⅔ ¼`), oklar gerçek okla.

| Rol | Font | pt/satır | Kullanım |
|---|---|---|---|
| `wordmark` | SF Pro Display Bold, tracking −0.6 | 40/44 (onboarding), 28/32 (About) | `nokta` + ayrı çizilen nokta katmanı |
| `title` | SF Pro Display Semibold | 22/28 | onboarding başlıkları |
| `body` | SF Pro Text Regular | 13/16 | her şey |
| `callout` | Regular, secondary | 12/15 | tek satır yardım |
| `caption` | Regular | 11/14 | `Measured now.`, sahne yazıları |
| `digits` | `monospacedDigitSystemFont` | 13/16 (About değerleri Semibold) | canlı sayılar, slider okumaları |
| `mono` | `monospacedSystemFont` | 11/14 | About › Details (lsof, entitlement) |
| `keycap` | SF Pro Medium | 12 (chip), 18 (sahne tuşları) | tuş kapakları |
| `plate` | SF Pro Text Semibold | 15/20 | etiket plakası |

### 4.4 Boşluk, yarıçap, çizgi
- **Boşluk ölçeği:** 4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 64.
- **Yarıçaplar:** `r.s` 6, `r.m` 10, `r.stage` 12, `r.overlay` 12 (macOS 14–15) / 16 (macOS 26+, **P**).
- **Overlay çizgisi:** `line.w = ceil(2·scale)/scale` (IC'de 3 pt), böylece 1x'te 2 px, 1.5x'te 3 px olur. Path köşeleri yarım piksele hizalanır ve `contentsScale` her zaman ekranın ölçeğidir.
- **Gölge yok.**

## 5. Hareket

### 5.1 Token'lar
| Token | Değer | Kullanım |
|---|---|---|
| `ease.out` | (0, 0, .2, 1) | girişler, fade-in, basış |
| `ease.in` | (.4, 0, 1, 1) | çıkışlar, iptal |
| `ease.glide` | (.2, 0, 0, 1) | konum değişimi, uçuş |
| `ease.land` | (.34, 1.32, .64, 1) | nokta damgası, iniş (tepe 1.034, ≈ %3.4 aşma; SelfTest bunu doğrular) |
| `ease.hand` | (.42, 0, .58, 1) | sahnedeki imleç ve el hareketi |
| `step` | ayrık | pencere tek adımda oturur, glif değişimi |
| `linear` | — | Reduce Motion çapraz geçişleri, renk |

**Süreler (ms):**

| Ne | Süre |
|---|---|
| `dur.fade` | 90 |
| `dur.draw` (çizgi çizilir) | 160 |
| `dur.move` | 140 |
| `dur.cancel` | 120 |
| `dur.commit` | 260 |
| `dur.flash` | 240 |
| `dur.stamp` (nokta) | 100 |
| `dur.shake` | 180 |
| `dur.label` | 90 giriş / 700 bekleme (engellendi: 2000) / 160 çıkış |
| `dur.page` | 320 |
| `dur.flight` | 360–400 |
| `dur.rm` (Reduce Motion) | 100–150, linear |

Demolarda `preferredFrameRateRange` 30…60'tır (tercih 60); ProMotion'da 120 Hz'e çıkmaz.

### 5.2 `pose(at t)` sözleşmesi (bağlayıcı)
Her hareketli yüzey (overlay, plaka, üç sahne, sayfa geçişi, izin anı) saf bir `Timeline` tanımlar. Tip taslağı `design-v2-opus.md` §Hareket'tedir: `Ease`, `Key`, `Track`, `Timeline`, `pose(at:)`, `animations(begin:loops:)`. Dosya: `app/Sources/UI/Motion/Timeline.swift`; AppKit'e bağımlı değildir.

1. **Tek kaynak.** `pose(at:)` ve `animations(...)` aynı `keys` dizisinden üretilir. Her track bir `CAKeyframeAnimation` olur: `values`, `keyTimes` (= t / duration), segment başına `timingFunctions`; `step` için `calculationMode .discrete`. `Ease.y` kübik Bézier'dir ve `CAMediaTimingFunction` ile aynı sonucu verir. Yay hareketi 12 örnekli polyline olarak verilir.
2. **Render server.** Animasyonlar tek bir `CATransaction` içinde eklenir. Kare başına ana thread işi sıfırdır. Animasyon için timer ya da display link kullanılmaz.
3. **Model hep dinlenme pozunda.** Oynatmadan önce, aksiyonlar kapalıyken `apply(pose(at: restT))` yapılır. Animasyonlar `isRemovedOnCompletion = true` ile eklenir; `fillMode .forwards` ile asılı kalan animasyon olmaz.
4. **Sınırlı döngü.** `loops > 1` olunca `repeatCount = n` olan bir `CAAnimationGroup` eklenir. Ardından `begin + n·duration` anında bir kuyruk grubu (0 → `restT`) gelir; kuyruk yalnız `0 < restT < duration` iken eklenir (aksi hâlde fazladan bir tur olurdu). Sonsuz `repeatCount` yasaktır.
5. **Kesintiden devam.** Kesilebilen geçişler `move(from: presentationPose, to:)` ile o anda üretilir. Örnekler: bölge değişimi, izin anı.
6. **Görünürlük kapısı (`MotionGate`).** Sahne yalnız şu koşulların hepsi doğruyken oynar: `window.isVisible`, `occlusionState.contains(.visible)`, `!NSApp.isHidden`, ekran uyanık, pencere küçültülmemiş, Reduce Motion kapalı.
   - Kapı kapanınca (`didChangeOcclusionState`, `willMiniaturize`, `didHide`, `screensDidSleep`, sayfa değişimi, `windowWillClose`) ağaçta `removeAllAnimations()` çalışır ve `restT` pozuna geçilir.
   - Kapı açılınca döngülü sahneler sayacı sıfırlayıp baştan başlar. Tek seferlik sahne (A) yalnız hiç oynamadıysa oynar.
   - Overlay'de her geçiş `orderOut` + `removeAllAnimations` ile biter.
7. **Reduce Motion.** Her timeline'ın bir `explainT` pozu vardır ve bu poz tek başına anlamlı bir resimdir. Reduce Motion açıkken yalnız bu poz ve 100–150 ms linear çapraz geçişler kullanılır. Değişiklik `AccessibilityEnv` bildirimiyle gelir; polling yok.
8. **Snapshot.** `tools/snapshot` animasyon eklemez; `apply(pose(at: t))` yapıp çizer. Her timeline için storyboard karelerini PNG olarak, sahneleri de GIF olarak üretir. GIF'ler yalnız inceleme içindir; pakete girmez. Böylece v1'deki boş `overlay-label` render'ı sorunu da kapanır.
9. **Testler.** `scripts/snapshot.sh` render'dan önce `tools/snapshot/SelfTest.swift`'i koşturur ve bir hata çıkarsa sıfırdan farklı kodla çıkar. Kontroller:
   - `Ease.y`, CA kontrol noktalarıyla bilinen örneklere ±1e-4 içinde eşittir.
   - Her `Timeline` için `pose(0)` ve `pose(duration)` beklenen anahtar değerlerine eşittir.
   - Döngülü demolarda `pose(0) == pose(duration)`.
   - `animations(...)`: her track'te `keyTimes` sayısı `values` sayısına eşittir ve `timingFunctions` sayısı segment sayısına eşittir.
   - Opaklık 0…1 aralığındadır; `keyTimes` artandır.
   - Overlay path'i her `AnchorSide` × yatay/dikey için aynı eleman sayısına sahiptir.

## 6. Ses ve haptik
v1 ile aynıdır: kodla sentez, varsayılan kapalı, `tick` / `tick.soft` / `thud` / `ready` tablosu, 90 ms rate limit, uiaudio kontrolü. Haptik varsayılan açıktır: bölgeye girişte ve bölge değişiminde `.alignment` (80 ms'de ≤ 1); gap slider'da `.levelChange`. v1 §6 metni değişmeden geçerlidir.

**Değişen tek şey:** Settings'te önizleme butonu yok. `Sound` açılınca `ready` bir kez çalar.

## 7. Menü bar

### 7.1 İkon
18 × 18 pt template görüntü, kodla çizilir. Üç görüntü önbellekte tutulur ve yalnız durum değişince değişir. Ölçüler `design-v2-opus.md` §3.1'dedir: çerçeve 12 × 8.5, r 2.25, 1.5 pt; nokta Ø 3, çerçevenin dışında, alt kenarı çerçevenin alt kenarıyla aynı hizada.

| Durum | Şekil (durumlar şekille ayrılır, yalnız alfa ile değil) | `accessibilityValue` |
|---|---|---|
| Active | çerçeve + sol yarı dolu + dolu nokta | `On` |
| Paused | yalnız çerçeve + halka nokta | `Paused` |
| Needs permission | çerçeve + çapraz çizgi (iki yanında 1 pt şeffaf boşluk), nokta yok | `Needs Accessibility access` |

- IC'de çizgiler 2 pt olur.
- 1x'te çizgiler tam piksele oturur.
- **Hiçbir zaman animasyon yok.** Snap geri bildirimi, ilk ışık ve nabız yok; v1'deki "ilk ışık" silinir.

### 7.2 Menü
**İlke: her şey yolundayken menü durum söylemez.** Durumu ikon zaten gösteriyor. Metrikler About'tadır.

```
[durum yuvası — yalnız gerektiğinde, altında ayraç]
▭ Left Half          ⌃⌥←      glif: FrameGlyphs.action, 16×12 template
▭ Right Half         ⌃⌥→
▭ Top Half           ⌃⌥↑
▭ Bottom Half        ⌃⌥↓
▭ Maximize           ⌃⌥↩
▭ Almost Maximize   ⌃⌥⇧↩
▭ Center             ⌃⌥C
  Restore            ⌃⌥⌫
  Quarters             ▸     Top Left · Top Right · Bottom Left · Bottom Right
  Thirds               ▸     First · Middle · Last · First Two · Middle Two · Last Two
  Display              ▸     Next · Previous
────
  Pause                      (Paused iken: Resume)
  Ignore “Safari”            (eklenmişse: Stop Ignoring “Safari”; 64 doluysa: Ignore list full, disabled)
────
  Settings…          ⌘,
  Quit Nokta         ⌘Q
```

**Durum yuvası.** Tek bir öğedir; birden çok koşul varsa öncelik sırası tablodaki gibidir.

| Koşul | Öğe | Görsel | Eylem |
|---|---|---|---|
| izin yok | `Allow Accessibility…` | R3 | onboarding ekran 2 |
| izinli ama kurulum bitmemiş | `Finish Setup…` | — | onboarding |
| VoiceOver yüzünden ⌃⌥ askıda | `Shortcuts paused for VoiceOver…` | — | Settings › Shortcuts |
| event tap kurulamadı | `Drag snapping unavailable` (tooltip `Drag snapping could not start.`) | — | Settings › About |
| çekirdek durdu | `Nokta stopped…` | — | Settings › About |

- Kısayollar her zaman gösterilir; tercih silinir.
- `menuNeedsUpdate` yalnız `checkHealth()` ve `rebuild()` yapar, hedef ≤ 0.3 ms. Menüde `IntegrityProbe` çağrılmaz.
- Menüden snap davranışı v1 ile aynıdır: menü kapanınca, önceki ön plan uygulamasına uygulanır.
- **Bench modları:** menüde yalnız `Quit Nokta` etkindir; bütün eylemler, Pause/Resume, Ignore ve `Settings…` kapalıdır, durum yuvası gizlidir. `AppController` ayrıca kısayol bağlamayı, `setPaused`'ı, `perform`'u, Settings ve onboarding pencerelerini açmayı bench modunda reddeder; kullanıcı ölçüm sırasında menüye tıklasa da hiçbir pencere taşınmaz, hiçbir kısayol kaydedilmez. Menü açılışı ve kapanışı `NOKTA_BENCH_EVENT menu-open` / `menu-close` yazar (BENCHMARKS).

## 8. Settings
**Pencere:**
- `NSTabViewController(.toolbar)`, `.preference`, genişlik 560 pt, iç kenar 20 pt.
- **4 sekme:** General · Shortcuts · Dragging · About.
- Sekme kısayolları ⌘1–⌘4.
- SF Symbols: `gearshape`, `keyboard`, `macwindow.on.rectangle` (yoksa `rectangle.split.2x1`), `info.circle`.

**Satır kuralları:**
- `NSGridView`: etiket solda, kontrol sağda.
- **Grup başlığı yok.** Gruplar 20 pt boşlukla ayrılır.
- Yardım satırı en fazla bir satır callout'tur. Ek bilgi tooltip'e gider.

| v1 sekme | v2 |
|---|---|
| General | General (+ Ignored apps) |
| Shortcuts | Shortcuts (+ Flash after snap, Almost Maximize) |
| Snapping | Dragging (Keyboard grubu ve Preview kalktı) |
| Rules | General'e katıldı |
| Integrity | About |

**General** (≈ 420 pt):
- `Open at login` (switch). Altında koşullu `Needs approval.` + [Open Login Items…]; yalnız `.requiresApproval` durumunda görünür.
- `Show in menu bar` (switch). Altında `Open Nokta again to return here.`; yalnız switch kapalıyken görünür.
- 20 pt boşluk.
- `Sound` (switch; açılınca `ready` çalar; tooltip `A short tick at alert volume.`).
- `Haptics` (switch; tooltip `Force Touch trackpads only.`).
- `Snap labels` [Never | When needed | Always]; "When needed" tooltip'i: `Size changes, display moves and problems.`
- 20 pt boşluk.
- `Ignored apps` (body semibold; tooltip `No shortcuts or drag snapping in these apps.`).
  - Altında NSTableView: 3 görünür satır × 28 pt, ikon 20 + ad. Bundle id satırda değil, tooltip'te.
  - Boş durum ortalı: `Drop apps here.`
  - Butonlar [+ ▾] [−]. + menüsü: Running Apps, `No other apps running`, Choose App….
  - .app sürükle-bırak kabul edilir. 64 sınırı ve davranış v1 ile aynı; metinler §10.2'de.
- Ayraç + [Reset All Settings…].

**Shortcuts** (≈ 600 pt):
- Tablo 300 pt yükseklikte ve kayar; satır 28 pt.
  - Grup satırları: HALVES · QUARTERS · THIRDS · SIZE · DISPLAY.
  - Her satır: glif + ad + ShortcutRecorder (150 × 24) + temizle butonu.
- `Shortcut set` [⌃⌥ | ⌥⌘ | ⌃⇧⌘] (adlar tooltip'te); altında `⌃⌥ Classic. ⌥⌘ as in Spectacle and Tiles. ⌃⇧⌘ avoids the VoiceOver keys.`
- `Repeat to cycle ½ ⅔ ⅓` (switch).
- `Flash after snap` (switch).
- `Almost Maximize`: slider 50–100, 11 tik, okuma digits ile (`90 %`).
- `Keep ⌃⌥ with VoiceOver`: yalnız VoiceOver açıksa ya da switch açıksa görünür. Altında `For Caps Lock as VO key.`; askıdayken bunun yerine `⌃⌥ shortcuts paused.`
- [Restore Defaults] [Practice…]. Practice onboarding'in alıştırma ekranını açar (izin varsa doğrudan ekran 3). Restore Defaults: özel (hiçbir sete uymayan) kısayollar varken önce sorar: `Restore the default shortcuts?` / `This replaces your custom shortcuts.` [Restore] [Cancel]; bir setten (Alternate) dönüşte sormaz.
- **ShortcutRecorder.** Kayıt modunda R2 noktası ve `Type shortcut…` görünür. Klavye sözleşmesi:
  - Space / Return (satırda veya odaklı recorder'da) kaydı başlatır; yalnız Nokta'nın key penceresinde (başka yerde tuş gelmez, kısayollar boşuna askıda kalırdı).
  - Esc (değiştiricili de) iptal eder, eski kısayol kalır; VoiceOver `Cancelled. Left Half is still …` der.
  - ⌫ / ⌦ temizler. Tab / ⇧Tab kaydı bırakır ve odak listeden sonraki / önceki kontrole geçer (geri listeye çekilmez).
  - Kayıt sürerken hiçbir Nokta kısayolu kayıtlı değildir; iptal, pencere kapanması, kaydın penceresinden çıkması ve hata yolları her kısayolu tam bir kez yeniden kaydeder. Yeni kısayol, kayıt bitmeden kaydedilir: eski hiç arada geri kaydedilmez.
  - Reddedilenler (kayıt sürer, satırda neden): değiştiricisiz ya da yalnız ⇧ (F-tuşları hariç) `Add ⌃ or ⌥.` · yalnız ⌘ / ⇧⌘ `Apps use ⌘ shortcuts. Add ⌃ or ⌥.` · macOS'un etkin sistem kısayolları (`CopySymbolicHotKeys` + ⌘⇥, ⌥⌘⎋, ⌃⌘Q, ⌥⇧⌘Q) `macOS uses this shortcut.`
  - Kayıt başarısızsa (başka uygulama tutuyor) önceki kısayol geri konur: `⌃⌥X is in use by another app. Kept ⌃⌥←.` Açılışta başarısız olan kayıtlı kısayol değiştirilmez, `Taken by macOS or another app.` der.
  - Satır altı diğer notlar: `Used by “Center”.` [Swap] [Cancel] · `Option-only fails on macOS 15.0–15.1.` · kayıtlı kısayol sistemle çakışıyorsa `macOS uses this shortcut.` Swap iki kısayolu tek değişiklikte, iki geçişte bağlar (Carbon'dan hiçbir an başka eylemin tuttuğu kombinasyon istenmez).
  - Tuş kimliği sanal tuş kodudur (fiziksel konum; düzenden bağımsız, saklanan budur); gösterilen ad o anki klavye düzeninden gelir (Türkçe Q'da kVK_ANSI_LeftBracket `Ğ`, US'de `[`). Menü aynı karakteri gösterir (otomatik key-equivalent yerelleştirmesi kapalı).

**Dragging** (≈ 640 pt):
- `Drag to snap` (switch).
- **ZoneMap v2** (384 × 240):
  - Ekranın dış çizgisi çizilir, üzerinde kenar ve köşe tutamakları ile alt kenarda 3 segment bulunur.
  - Seçili tutamağın sonuç bölgesi mini ekran içinde, overlay'in çizgi stiliyle çizilir. Önizleme yalan söylemez; aynı geometri kullanılır.
  - Hücre ızgarası ve hücre içi metin yok. Ayarlarda kırmızı yok.
  - Ölçüler, durumlar, isabet alanları (köşe 44 × 44, kenar 32 × 96, üst kenar 120 × 32, segment 120 × 32) ve klavye davranışı (tek Tab durağı, oklar saat yönünde, Space popup'ı açar): `design-v2-opus.md` §3.3.3. Alt segment çubukları 72 pt'tir (80 pt köşe kollarıyla çakışıyordu).
  - Sonuç bölgesi çekirdeğin `nk_layout_frame`'i ile, gerçek kullanılabilir alan ve güncel gap/margin/Almost Maximize ile hesaplanıp ölçeklenir. Center'ın sabit hedefi olmadığı (pencere kendi boyutunu korur) için kesik çizgili, sembolik bir kutu olarak çizilir.
- `Left edge` [popup]: etiket seçili tutamağın adıdır (`Right edge`, `Top left corner`, `Bottom edge, left` …). Popup içeriği v1'deki menü bölümleridir.
- `With ⇧` [popup]: alternatif harita; Alternate key `None` ise satır gizlenir.
- `Alternate key` [None | ⇧ | ⌃ | ⌥ | ⌘]. Altında `macOS also tiles while ⌥ is held.`; yalnız ⌥ seçiliyken ve sistem hızlandırıcısı açıkken görünür. Sistem ayarı okunamıyorsa (bilinmiyor) temkinli davranılır ve satır `macOS may also tile while ⌥ is held.` olarak görünür.
- `Sensitivity` [Tight | Normal | Wide]; tooltip seçime göre `Edge 5 pt · corner 32 pt`.
- `Restore size on drag out` (switch).
- `Snap where displays meet` (switch, varsayılan kapalı).
- `Gap`: slider 0–24, adım 4, okuma digits ile (`8 pt`); haptik `.levelChange`.
- `Margin`: aynı slider.
- Sistem tiling kartı, yalnız algılanırsa: `macOS tiling is also on.` [Open Desktop & Dock…]. Bilinmiyorsa `macOS may also tile windows.`; Stage Manager açıksa `Stage Manager may take dropped windows.`

**About** (≈ 300 pt kapalı, 470 açık):
- Üst satır: `nokta.` (wordmark 28; noktası kırmızı R6) ve sağda `0.2.0 · arm64`.
- `Memory` 11.8 MB + LineMeter (120 × 12; iz 2 pt ink.3, dolgu ink; 12 MB tikini aşan kısım R5). Aşınca yanında `over 12 MB target`.
- `Last snap` 0.6 ms; tooltip `From key press or drop to the last window call. Screen refresh not included.`
- `Network` 0 sockets (AF_INET/6 soket sayısı).
- Sağda caption: `Measured now.`
- `▸ Details` disclosure, varsayılan kapalı:
  - `Snap times`: median · p95 · n
  - `Since launch`: CPU · threads
  - `Accessibility`
  - `Entitlements`
  - `Signature`
  - `Telemetry None` · `Updates Manual`
  - `Check` `lsof -a -i -p <pid>` [Copy]
- [Copy Report] · [Refresh] (⌘R).
- Ölçüm sekme görününce, ⌘R'de ve her snap'te yapılır; timer yok. n = 0 iken `—`; ölçüm okunamazsa `Unreadable`.
- Doto kredisi ve `License…` kalkar.

## 9. Snap overlay
**Pencere v1 ile aynı:**
- Ekran başına lazy `NSPanel`: borderless, nonactivating, tıklamayı geçirir, `.floating`, tam ekran frame.
- Gizliyken `orderOut`.
- `draw(_:)` yok.

**Katman ağacı** (8 katman, bitmap yok):
```
root (flipped, ekran boyu, durağanken hidden)
 ├─ shape            container; iptal, commit ve flash bunu soldurur
 │   ├─ scrim  CALayer       bg ov.scrim, cornerRadius r.overlay, cornerCurve .continuous
 │   ├─ halo   CAShapeLayer  path = line ile aynı, lineWidth line.w + 2, stroke ov.halo
 │   └─ line   CAShapeLayer  path = hedef dikdörtgen, lineWidth line.w, stroke ov.line
 ├─ period    CALayer       Ø 8 red (R1), cornerRadius 4; DWC açıkken 1.5 pt ink halka
 └─ plate     CALayer       plate.fill, pill
     └─ text  CAShapeLayer  SF Semibold 15 glif ana hatları (`GlyphPath`), dolgu plate.text
```

**Geometri:**
- **Hedef** = çekirdeğin `layout.frameFor` sonucu (gap ve margin dahil).
- **Giriş noktası E:** dokunulan kenarın orta noktası; alt segmentte segmentin altı. Köşe bölgesinde E köşe yayının saat yönündeki ucudur (yayın ortası değil): böylece her kenar ve köşe için path aynı yapıdadır (4 doğru + 4 yay), bölge değişiminde `path` sorunsuz ara değer alır ve E path üzerinde tam 0.5'e düşer. Sürüklemede E her zaman bölgeden (`AnchorSide(zone:)`) gelir: çizgi, imlecin olduğu kenara bakan taraftan büyür. Klavyede eylemden (`AnchorSide(action:portrait:)`).
- **Path sözleşmesi:** `FrameGeometry.path(rect:radius:start:)` her zaman 4 doğru + 4 yay (`addArc`; yarıçap 0 olsa bile) üretir ve saat yönünde ilerler.
  - Başlangıç E'nin **karşısındaki** noktadır; bu nokta çevrenin yarısı kadar uzaktadır.
  - Böylece E path üzerinde 0.5'e düşer.
  - Giriş animasyonu `strokeStart` 0.5 → 0 ve `strokeEnd` 0.5 → 1 olur: çizgi E'den iki yöne doğru büyür ve karşı kenarda kapanır.
- **Nokta konumu:** hedefin alt-son iç köşesi (LTR'de sağ alt), (maxX − 14, maxY − 14). Kısa kenar 64 pt'den küçükse merkez.
- **Neden böyle:** tam ekran shape layer, render server'da ekran boyu doku demektir. Burada animasyonlar yalnız `strokeStart/End`, `path`, `bounds`, `position`, `opacity`, `lineWidth` ve `transform` üzerinde.

**Zaman çizelgeleri:**

| ID | Olay | Normal | Reduce Motion |
|---|---|---|---|
| O1 giriş | bölgeye giriş | scrim α 0 → 1, 90 ms `out`; `strokeStart` 0.5 → 0 ve `strokeEnd` 0.5 → 1, 160 ms `out`, 20 ms gecikmeli; haptik `.alignment`; VoiceOver eylem adını duyurur (300 ms'de ≤ 1) | shape opaklığı 0 → 1, 100 linear, çizgi tam |
| O2 kayma | bölge değişti | `path`, `scrim.bounds/position` 140 ms `glide`, `fromValue = presentation()`. Giriş sürüyorsa `strokeStart/End` animasyonları kaldırılır ve model tam çizgiye geçer. | anında |
| O3 iptal | bölge dışında bırakma | shape opaklığı → 0, 120 ms `in` → `orderOut` | 100 linear |
| O4 commit | `DROP` bayrağı | `lineWidth` line.w → 3 pt (IC'de 4) ve scrim tepe α .40, 0–80 ms `out`; nokta scale 0 → 1, 40–140 `land`; root opaklığı → 0, 100–260 `out` → `orderOut`. AX set t = 0'da yapılır; ses açıksa `tick`. | nokta ölçeksiz belirir; root → 0, 120 linear |
| O5 flash | klavye/menü snap'i ("Flash after snap" açıksa) | Çekirdeğin geri okuduğu **gerçek** çerçeve, dolgusuz, çizgi 3 pt ve tam. Nokta 0–100 `land`; root 60–240 `out` ile söner. Ardışık basış öncekini keser. | nokta ölçeksiz; fade 160 linear |
| O6 engellendi | `failed` | Plaka x ±4 pt, 3 yarım salınım, 180 ms; çerçeve biliniyorsa 1.5 pt dolgusuz çizgi, nokta yok | 60/60 ms iki opaklık nabzı |
| O7 etiket | §10 kuralı | Plaka: 0–90 belirir `out`, 700 ms bekler (engellendi 2000), 160 ms'de söner `in`. Sonraki snap etiketi hemen değiştirir. | aynı (yalnız opaklık) |

- Bitmeyen işe nokta konmaz: nokta yalnız O4'te ve O5'te çıkar; iptal noktasızdır.
- **Çoklu ekran:** önizleme yalnız imlecin ekranında olur; diğer paneller anında gizlenir (`hideOthers`). Her yüzey kendi `backingScaleFactor`'ını kullanır.
- **Dikey ekran:** üçte birler satır olur (çekirdek). Sürüklemede başlangıç yine bölgeden gelir (imlecin kenarı); klavye flash'ında eylemden.
- **Çentik:** bölgenin tepesi kullanılabilir alanın tepesidir. Çentik bandına öğe çizilmez; plaka `visibleFrame` içine sıkıştırılır.
- **Dinlenme durumu:** her geçiş `reset()` ile biter ve `reset()` çerçeveyi saydam bırakır (shape ve scrim opaklığı 0, çizgi ve hale path'i boş). Çerçeveyi gösteren her zaman çizelgesi opaklıklarını kendi `base`'inde kurar; yalnız plaka gösteren etiket (O7, çerçevesiz O6) çerçeveyi gizli tutar. Böylece önceki bir pencerenin çerçevesi hiçbir durumda geri gelmez (OV2-1).
- **Kaldırılanlar:** Dots/Outline tercihi; `previewStyle` anahtarı artık okunmaz, Reset onu temizler. Strip, replicator ve kafes hizası.

## 10. Etiket (HUD) ve metin

### 10.1 Etiket kuralı
Ayar: General › Snap labels = Never · **When needed** (varsayılan) · Always.

| Durum | When needed | Always | Never |
|---|---|---|---|
| Boyut döngüsü (cycle > 0) | `Left ⅔`, `Left ⅓` (Right/Top/Bottom için aynı) | aynı | — |
| İlk basış (cycle 0) | — | `Left ½` … `Top Left` … `First ⅓` · `Middle ⅓` · `Last ⅓` · `First ⅔` · `Middle ⅔` · `Last ⅔` · `Maximize` · `Almost Maximize` · `Center` · `Restored` | — |
| Ekran değişimi | `Display 2` | aynı | — |
| Minimum boyut yüzünden büyük kaldı | `Can't get smaller` | aynı | — |
| Sabit boyutlu, yalnız taşındı | `Can't resize` | aynı | — |
| Engellendi | `No window` · `Can't move` · `Ignored app` · `Needs Accessibility` · `App didn't respond` | aynı | — |

- Tek satırdır. v1'deki "başlık + sebep" iki satırı kalkar.
- Nokta'nın kendi penceresi öndeyken `Can't get smaller` ve `Can't resize` bastırılır (v1).
- VoiceOver her durumda tam cümleyi duyar, Never seçiliyken de (`HUDText.spoken` korunur).
- Ekran numaraları yalnız aktif ekranlardan gelir; aynalanmış ya da kapalı (clamshell) ekran sayılmaz.

### 10.2 Metin tablosu (bağlayıcı)
Bütün yüzeylerin metni `design-v2-opus.md` §Metin tablolarındaki v2 sütunudur. Bu belgedeki farklar şunlar:

| Yer | Metin |
|---|---|
| Sekme adları | `General` `Shortcuts` `Dragging` `About` (öneride `Keyboard`/`Drag` idi) |
| General | `Snap labels` (öneride `Labels`); `Show shortcuts in menu` satırı yok; Sound önizleme butonu yok |
| Menü ve etiketler | Thirds alt menüsü ve etiketlerinde `Middle` (`Center` eylemiyle karışmasın diye) |
| Onboarding | §11 |

**Hedef:** toplam görünür metin ≤ 600 kelime (v1: 1116). İki kısa satırdan uzun paragraf hiçbir yerde yok.

## 11. Onboarding

**Genel:**
- **3 ekran.** Pencere 560 × 472 (0.4.0: ekran 3'ün alıştırma satırı, set seçici ve `Open at login` için bir satır daha; VoiceOver'a göre boy değişmez): titled, closable, fullSizeContentView, şeffaf titlebar; zemin `paper`. Açıkken `.regular`, kapanınca `.accessory` (v1).
- **Sahne kalıcı.** Üstte 480 × 200 Stage durur (r 12, `paper.raised`, hairline). Ekranlar arasında yalnız sahnenin *içeriği* değişir; çerçeve hiç kıpırdamaz. Metin sütunu kayar.
- **Alt bar:** solda ilerleme, 3 segment (20 × 3 pt, r 1.5, aralık 6; tamamlanan ve şimdiki `ink`, sıradaki `ink.3`; VoiceOver `Step 2 of 3`). Sağda butonlar.
- **Klavye:** Return primary, ⌘[ Back, Esc/⌘W Later. Sahneye tıklamak ya da Full Keyboard Access açıkken Space, sahneyi yeniden oynatır.
- Yerleşim ve koordinatlar: `design-v2-opus.md` §3.6.

| Ekran | Sahne | Metin | Kontroller | Primary |
|---|---|---|---|---|
| 1 Welcome | A sürükle-oturt (bir kez; tıklayınca yeniden) | yazı markası `nokta.` (noktası sahneden uçarak gelir) · `Drag a window to an edge, or press a shortcut.` | — | `Continue` |
| 2 Access | B izin anahtarı (beklerken ≤ 3 döngü + kuyruk) | `Allow Accessibility` · `Nokta needs it to move windows. Nothing leaves your Mac.` | Solda ● `Waiting…` (R4); sağda `Not working?` (NSPopover: `Remove Nokta with −, then add it again.`) | `Open System Settings` (Back ve Later görünür). İzin gelince `Continue` olur, Later gizlenir. |
| 3 Try (alıştırma) | C: yalnız sıradaki kısayolun büyük tuşları ve adı; tuşlar döngüde basar (2400 ms, ≤ 3); kullanıcı basınca durur, 6 s sessizlikten sonra yeniden; bitince `All set.` | `Try a shortcut` · 4 chip: `⌃⌥← Left`, `⌃⌥→ Right`, `⌃⌥↩ Maximize`, `⌃⌥⌫ Restore` (sıradaki ink çerçeveli, VoiceOver `next`; denenince ✓) · alıştırma satırı (aşağıda) | `Shortcuts` [Classic ⌃⌥ \| Option-Command ⌥⌘ \| Alternate ⌃⇧⌘] (her zaman); `Open at login` (switch, varsayılan açık) | `Done` |

- **İzinsiz ekran 3:** alıştırma satırı `Shortcuts start after you allow access. Snapline stays in the menu bar` + ikon; tuşlar hiçbir şeyi değiştirmez, chip çerçevelenmez.
- **Alıştırma satırı** (ekran 3; tuşlar keycap 13 ink, metin body secondary; VoiceOver tuşları heceler, yalnız sonuçlar duyurulur):
  - Adım: `Press ⌃⌥← to move this window left.` (→ `to move it right`, ↩ `to fill the screen`, ⌫ `to put it back`).
  - Değiştirici basılıyken: doğru olanlar yalnız sahnedeki tuşlarda basılı görünür (hareketsiz poz), satır adımda kalır; adımın kullanmadığı değiştiriciler satırda: `⌥⌘ held. This step uses ⌃⌥.`
  - Snap: `✓ ⌃⌥←. Next, press ⌃⌥→ to move it right.` (sürüklemeyle: `✓ Left Half. …`). Dördü bitince `All four work. Snapline stays in the menu bar` + ikon.
  - Pencereye ulaşan bir basış (Carbon Snapline'ın kısayollarını uygulamaya hiç ulaştırmaz): başka setin kısayolu `⌥⌘← is Left Half in Option-Command. Choose it below.` · bilinmeyen `⌃K is not a Snapline shortcut. Try ⌃⌥←.` · değiştiricisiz adım tuşu `Hold ⌃⌥ while you press ←.` · Snapline'ın kendi kısayolu `⌃⌥← reached this window, not Snapline: another app has it.` · VoiceOver askısı. ⌘ komutları, Tab, Return, yazı yok sayılır; olay tüketilmez.
  - Hata: `⌃⌥↩ reached Snapline, but: This window cannot be moved.`; boşta Restore `✓ ⌃⌥⌫ works. There was nothing to put back yet.` (sayılır).
  - Engel (boşta): kayıtlı olmayan adım `⌃⌥← belongs to Tiles. Quit it, or choose another set.`; çalışan pencere yöneticisi (Tiles, Spectacle, Rectangle, Magnet, Moom) `Tiles is running and answers keys too. Quit Tiles to practise.` Uygulama kapanınca Snapline yalnız alınamayan kısayolları yeniden kaydeder.
  - Tanıdık set: Tiles ya da Spectacle kurulu, kısayollar dokunulmamış Classic ve VoiceOver kapalıysa ekran 3 Option-Command ile açılır: `Option-Command keys, as in Tiles. Press ⌥⌘← …`.
- **Bir kez daha:** alıştırmadan önce kurulumu bitirmiş (ya da ekran 3'e varmadan kapatmış) kullanıcıya bir sonraki açılışta onboarding doğrudan ekran 3'te bir kez açılır (`practiceSeen.v1`, ekran 3 görülüp pencere kapanınca yazılır).
- **İzin algılama v1 ile aynı:** açılışta kontrol, `com.apple.accessibility.api` yayını, `didBecomeActive`, ve 1 Hz yedek timer (tolerance 0.5). Timer yalnız ekran 2 ekrandayken çalışır: uygulama gizli, ekranlar uykuda ya da pencere küçültülmüşken durur (Reduce Motion açıkken de). Başka bir pencerenin altında kalmak onu durdurmaz: kullanıcı izni System Settings'te verirken onboarding genellikle tamamen örtülüdür ve izin geldiği an Nokta öne gelip `Access granted.` anını göstermelidir (OV2V-1; sistem yayını cihazda doğrulanana kadar timer bu yolun güvencesidir). Butona basınca bir kez prompt + deep link.
- **Ekran açıldığında izin zaten varsa** granted pozu animasyonsuz çizilir.
- **Ses ve haptik onboarding'den kalktı** (Settings'te).
- **"Look for the dots." kalktı.** Yerini satır içindeki gerçek ikon alıyor.

**Storyboard'lar.** Kare tabloları `design-v2-opus.md` §3.6'dadır. Burada yalnız farklar yazılı.
- **A — Sürükle-oturt** (Opus Storyboard A, 2700 ms, bir kez). Önizleme v2 overlay stilindedir:
  - F5'teki köşe parantezleri yerine çizgi E'den kendini çizer: `strokeStart/End` 0.5'ten, 160 ms; scrim de belirir.
  - F7'de çizgi kalınlaşır (1.5 → 3).
  - F8'de nokta pencerenin sağ alt iç köşesine damgalanır (Ø 7).
  - F10–F11'de nokta `nokta.` yazı markasının yuvasına uçar. Bu, özel an 1'dir.
  - Reduce Motion'da `explainT` (1750) statik pozu ve noktası yerinde bir yazı markası gösterilir.
- **B — İzin anahtarı** (Opus Storyboard B, 3200 ms döngü, ≤ 3 + kuyruk; yalnız beklerken):
  - Soyut bir `Privacy & Security › Accessibility` paneli çizilir; Nokta satırında anahtar ve kendi çizdiğimiz imleç vardır.
  - Apple ekran görüntüsü, glifi ya da Apple metni kullanılmaz.
- **E — İzin verildi anı** (Opus Storyboard E):
  - R4 noktası başlığın nokta yuvasına uçar ve başlık `Access granted.` olur; gövde `Nokta can move windows now.` olur.
  - 1.8 s sonra nokta red'den ink'e döner. Sahne B anında "açık" pozuna geçer.
  - Zamanlama (inceleme sonrası, OV2-10): başlık sıralı değişir (eski 0–60 çıkar, yeni 60–120 girer), gövde de sıralı (eski 160–240, yeni 240–320); iki metin hiç üst üste binmez. Uçan noktanın yay kontrol noktası `(2·slot.x − dot.x, min(dot.y, slot.y) − 0.9·titleSize)`: nokta başlığın sonunun üstünden geçip yuvaya sağdan iner, başlık gliflerinin üstünden geçmez.
  - Ekran görünmüyorken izin gelirse sahne, ekran görünür olunca oynar. Bu, özel an 2'dir.
- **C — Alıştırma tuşları** (0.4.0): sahnede minyatür pencere yok — hareket eden gerçek penceredir (onboarding'in kendisi). Yalnız sıradaki kısayolun tuşları (64 pt, ortada) ve altında adımın adı (plate, ink.2).
  - Rehber: 2400 ms döngü, ≤ 3; tuşlar 600'de iner, 1000'de kalkar; restT 0 = dikiş, explainT 750 (tuşlar basılı).
  - Snap ya da sayılan Restore: sıradaki adımın tuşları 240 ms'de belirir (opaklık 0→1, ölçek 0.96→1). Dördü bitince tuş yok, ortada `All set` + kırmızı nokta.
  - Herhangi bir tuş rehberi durdurur; 6 s tuşsuz geçince yeniden başlar. Reduce Motion: explain pozu, hareket yok.
- **D — Ekran geçişi** (Opus Storyboard D, 320 ms): eski metin ve sahne içeriği 160 ms'de çıkar; yenisi 80. ms'de başlayıp 240 ms'de girer. Stage çerçevesi sabittir. Reduce Motion'da 150 ms linear çapraz geçiş.
- **İmleç:** Nokta'nın kendi ok yoludur (12 × 18; yol `design-v2-opus.md` §3.6). Sistem imleci kopyalanmaz.

## 12. İkonlar
- **Uygulama ikonu** (`tools/icon/render-icon.swift`, CoreGraphics):
  - 1024 tuval; gövde 824, r ≈ 185, düz `#111113`; ince iç çizgi `#FFF` α .08.
  - Pencere çerçevesi (203, 322, 520, 380), r 56, 28 px `#F5F5F3`; sol yarısı dolu.
  - Nokta Ø 76, `#FF4438`, merkez (783, 664), çerçevenin **dışında**.
  - Gradient yok.
  - `AppIcon.svg` `tools/icon/`a taşınır ve pakete girmez.
- **Menü glifleri** (`FrameGlyphs.action`, 16 × 12 template):
  - Çerçeve (0.5, 0.5, 15, 11), r 2, 1 pt.
  - Dolgu iç alanın (2, 2, 12, 8) `unitFraction` kadarı.
  - Center (5, 3.5, 6, 5); Almost Maximize (3, 3, 10, 6); Maximize tam.
  - Restore ve Display glifsiz.
  - Aynı glifler Shortcuts tablosunda ve Dragging popup'larında kullanılır.
- **Settings sekmeleri:** §8.

## 13. Çatışma çözüm tablosu (Opus ↔ Fable)
| Konu | Opus | Fable | Karar | Gerekçe |
|---|---|---|---|---|
| Önizlemenin imzası | köşe parantezleri E'den kilitlenir | çizgi dokunuştan kendini çizer | **çizgi kendini çizer**, E'den iki yöne | Tek öğe, daha az katman; en çizgi dışı ve en okunur jest; parantezler çerçeveyle tekrar ediyordu |
| Kırmızı nokta ne zaman | yalnız iş bitince (commit, flash) | önizleme boyunca dokunuş noktasında | **yalnız bitince** | "nokta bitirir": ad ile anlam örtüşür; önizleme sırasında kırmızı yok, bir yüzeyde ≤ 1 kuralı kolay |
| Nokta boyu | Ø 6 | Ø 8 (Ø 6 1920 px'te görünmüyor) | **Ø 8** | Fable'ın teşhisi doğru (v1 render) |
| Integrity | About sekmesi + Details | General'de "Measured" bloğu, sekme yok | **About** | General sade kalır; dürüstlük kaybolmaz, ayrıntı katlanır |
| Rules / Ignored apps | General'e katılır | ayrı `Apps` sekmesi | **General** | Tek tablo için sekme gereksiz; 4 sekme |
| Sekme adları | General · Keyboard · Drag · About | General · Shortcuts · Dragging · Apps | **General · Shortcuts · Dragging · About** | İçeriği en doğru adlandıran kelimeler |
| Menü durum satırı | yalnız ilgi gerekince | `Active · 11.8 MB · no connections` | **yalnız gerekince** | "sanki yok gibi"; metrik About'ta; menü açılışında ölçüm yok |
| ZoneMap | ekran çizgisi + tutamaklar + sonuç bölgesi | 3×3 hücre + glif + kesir | **tutamaklar** | Gerçek davranışı (kenara sürükle → bu bölge) doğrudan gösterir, metinsiz |
| Menü bar ikonu | çerçeve + dolgu + dış nokta; slash | çerçeve + dolgu; merkez nokta | **Opus** | Durumlar şekille ayrılır (slash evrensel "kapalı"); dış nokta = marka |
| İlk ışık | ömürde bir 300 ms | silinir | **silinir** | Menü bar hiç hareket etmez; ekran 3 ikonu satır içinde gösterir |
| Ekran 1 demosu | bir kez + nokta yazı markasına uçar | ≤ 3 döngü | **bir kez + tıklayınca yeniden** | Döngü uçan noktayla ikinci kırmızı yaratırdı; ekran 1 kısa görülür |
| Ekran 2 bekleme | anahtar döngüsü ≤ 3 | statik, yalnız izin anı | **döngü ≤ 3 + izin anı (Opus E)** | Kullanıcı tam bu adımda "nasıl yapılır" animasyonu istedi |
| Plaka metni | glif path (CAShapeLayer) | CATextLayer | **glif path (CAShapeLayer, `GlyphPath`)** | Önce CATextLayer seçildi, ölçüm bunu bozdu: CATextLayer süreç içinde rasterleştiriyor ve gizlendikten sonra da kalan ColorSync dönüşüm tabloları + arka depo bırakıyordu (`--bench-used` +2.1 MB, 352 KB'lık 6 tablo). Glif yolunu render server dolduruyor; fark ölçümde kayboldu. |
| Plaka rengi | ters (ink zemin) | paper.raised | **ters** | Her zeminde okunur; Nothing'in siyah/beyaz sertliği |
| Yazı markası | `nokta.` küçük harf | `Nokta.` | **`nokta.`** | Daha çizgi dışı; noktalama olarak marka |
| Sound önizleme | ▶ ikon buton | yok, açınca çalar | **yok** | Bir kontrol eksik, aynı bilgi |
| Show shortcuts in menu | kalır | silinir | **silinir** | Menü zaten kısayol kartı |
| Flash ve Almost Maximize | Keyboard sekmesi | General / Dragging | **Shortcuts** | Klavyeyle ilgili olan tek yerde |
| Gap, Margin | Drag | Dragging | **Dragging** | İkisi de aynı |
| Etiket metinleri | `Can't get smaller`, `This window can't move` | `Minimum size`, `Can't move` | `Can't get smaller` · `Can't resize` · `Can't move` | En kısa insan cümlesi |

## 14. Özel anlar (3)
1. **Çizgi dokunduğun yerden çıkar** (O1). Kenara değdiğin an çerçeve oradan iki yöne doğru kendini çizer; bıraktığında kalınlaşır ve köşesine kırmızı nokta konur (O4). Her snap'te, ≤ 260 ms. Reduce Motion'da fade.
2. **`nokta.`** (ekran 1, A F10–F11). Demo penceresi oturur, köşesindeki nokta yazı markasının sonuna uçar. Bir kez; sahneye tıklayınca yeniden. Reduce Motion'da nokta baştan yerinde durur.
3. **`Access granted.`** (E). Bekleyen kırmızı nokta, izin geldiği an başlığın noktası olur ve 1.8 s sonra ink'e döner.

## 15. Erişilebilirlik
VoiceOver etiketleri `design-v2-opus.md` §Erişilebilirlik tablosundaki gibidir. Matris:

| Ayar | Overlay | Flash / etiket | Settings / Onboarding | Menü bar |
|---|---|---|---|---|
| Reduce Motion | yalnız fade (§9 RM sütunu) | fade | çapraz geçiş; sahneler `explainT` statik pozu | zaten hareketsiz |
| Reduce Transparency | scrim α .80, hale .95 | plaka zaten opak | opak | sistem |
| Increase Contrast | çizgi 3 pt α 1, hale .90, commit 4 pt | plakaya kenar | IC token'ları, raised + ink kenar | çizgi 2 pt |
| Differentiate Without Color | noktaya 1.5 pt ink halka | — | kırmızının yanında hep metin ya da şekil | şekil (dolgu, halka, slash) |
| VoiceOver | öğe değil; bölge değişimi duyurulur (300 ms'de ≤ 1) | etiket metni duyurulur (Never'da da) | tüm kontroller etiketli; sahneler role image + label + `Replay`; ZoneMap tutamakları popUpButton | title `Nokta` + value |
| Full Keyboard Access | — | — | mantıksal Tab sırası; ⌘1–4; Return/Esc/⌘[; ZoneMap tek Tab durağı + oklar | ⌃F8 |

- Hiçbir bilgi yalnız sesle ya da haptikle verilmez.
- En küçük hedef 24 × 24 pt.
- UI metinleri şimdilik kodda İngilizce literal'dir; yerelleştirme (Türkçe) yol haritasındadır ve `Localizable.strings`'e taşınarak yapılacaktır.

## 16. Performans bütçesi
| Ölçü | v0.1 | v2 hedefi |
|---|---|---|
| Idle CPU / wakeup | %0.00 / 0 | %0.00 / 0 |
| `phys_footprint` idle | 11–12 MB | ≤ 12 MB (hedef 11.7) |
| `phys_footprint` kullanım sonrası | 13.0 MB (FAIL) | ≤ 12 MB (ölçülen v2: 11.9–12.3 MB, medyan 12.2; kalan fark ilk kullanımda oluşan kod/metadata ≈ 0.23 MB + malloc'un tuttuğu boş sayfalar ≈ 0.4 MB; BENCHMARKS) |
| Paket | 1.27 MB | ≤ 950 kB (ilk tahmin 0.8 MB; ölçülen v2 ≈ 926 kB: binary + 100 kB ikon) |
| Binary (arm64) | 667 KB | ≤ 850 kB (ilk tahmin 700 KB; ölçülen v2 ≈ 822 kB. Artış onboarding sahneleri, Timeline ve Settings'in yeni görünümlerinden; `#if NOKTA_SNAPSHOT` ile ayrılan kod WMO + dead-strip ile zaten atılıyordu, ölçümle doğrulandı) |
| Soğuk açılış (sıcak p95) | 94.6–126.5 ms | < 150 ms |
| `menuNeedsUpdate` | ≤ 0.5 ms | ≤ 0.3 ms |
| Overlay görünürken | ≤ 1.5 MB | Δ ≤ 0.5 MB, gizliyken ≤ 0.1 MB |
| Onboarding açıkken | ≤ +5 MB | ≤ +5 MB (**ölçülen FAIL**: ~24 MB, kapanınca da kalıyor; BENCHMARKS not 4); demo oynarken Nokta CPU ortalama ≤ %0.5, sonra %0.0 |
| Settings açıkken | ≤ +6 MB | ≤ +5 MB; kapanınca idle'a ±0.3 MB içinde döner (**ölçülen FAIL**: açıkken 34–52 MB, kapanınca 33–48 MB; AppKit süreç önbellekleri — çözüm ayrı UI süreci, BENCHMARKS not 4) |

**Karşılığında kalkanlar:**
- Doto (diskte 457 KB; CoreText heap'i; kayıt süresi).
- Strip ve plaka bitmap'leri (freed-but-dirty sayfalar).
- 480 replicator örneği, `LatticeDemoView`, `DotMeter`.
- Menü açılışındaki ölçüm, Ready ekranı ve önizleme stili kod yolu.

## 17. Kabul ölçütleri (uygulayıcı)
1. `otool -L` çıktısında SwiftUI, WebKit, AVFoundation ve Metal.framework yok. `Contents/Resources` içinde font, PNG ya da GIF yok; yalnız `.icns` ve plist.
2. **Timer envanteri:** `Timer|DispatchSourceTimer|CADisplayLink|CVDisplayLink` yalnız onboarding ekran 2'de. `repeatCount` yalnız `Timeline` oynatıcısında ve sonlu; `.infinity` yok.
3. Her overlay ve sahne animasyonundan sonra `animationKeys()` boş; panel `isVisible == false`.
4. Bölge değişim sayısı kabuktaki `CATransaction` sayısına eşit (debug sayaç).
5. `red` token'ı yalnız R1–R6 kod yollarında kullanılıyor.
6. `scripts/snapshot.sh` SelfTest'i geçiyor. Her timeline için storyboard kareleri ve sahne GIF'leri üretiliyor. Bütün Settings sekmeleri ve onboarding ekranları (izinli ve izinsiz) açık ve koyu modda render ediliyor. Gerçek controller dizilerini çizen `overlay-seq-*` sahneleri (geçiş → bitiş → yalnız plaka) ve bench/yeniden-izin menü durumları (`menu-bench`, `paused-regranted`) denetleniyor; Settings'te her tıklanabilir öğe ≥ 24 × 24 pt denetimi var.
7. Ses: v1 ölçütleri (PCM tepe ±0.5 dB, uçlar 0, 90 ms rate limit).
8. Accessibility Inspector: Settings ve Onboarding'de 0 uyarı; özel kontrollerde label + value.
9. Settings ve Onboarding kapanınca controller'lar dealloc oluyor; `leaks` 0.
10. Activation policy: ikisi de kapalıyken `.accessory`.
11. Ana menüde Edit menüsü var.
12. `--bench-used`: O1 + O4 + O5 + O7'yi sentetik olayla çalıştırıyor (çekirdek yok). Footprint ≤ 12 MB.
13. Toplam görünür metin ≤ 600 kelime (§10.2).

## 18. Açık doğrulamalar (P)
- Haptiğin arka plan uygulamasında çalışması.
- `com.apple.accessibility.api` bildirimi.
- macOS 26 köşe yarıçapı (12 / 16).
- Liquid Glass menü barında ikonun okunurluğu (açık ve koyu duvar kağıdı, Reduce Transparency).
- 4K ölçekli modlarda çizgi keskinliği (1.5x).
- Clamshell + tek harici ekranda yüzeylerin yeniden kurulması.
- Onboarding demolarında WindowServer yükü (`top`).
- Gerçek Accessibility panelinin illüstrasyonla tutarlılığı.
- `com.apple.sound.uiaudio.enabled` domain'i.
- Alternate set çakışmaları.
