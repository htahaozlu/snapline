# Testing

## Otomatik
| Komut | Kapsam |
|---|---|
| `zig build test` | Saf çekirdek (types, geometry, layout, zones, rules), engine + mock (drag pipeline dahil), C ABI düzen kontrolü (Zig `comptime` + C `_Static_assert`) |
| `scripts/check-stubs.sh` | Ürün kodunda `not implemented` panic / `fatalError` / STUB kalmadığını doğrular |
| `zig build bench` | Kendi test penceresi (`NOKTA-BENCH-…`) üzerinde AX gecikmesi + doğruluk, headless açılış, idle ve **kullanım sonrası idle** (`--bench-used`: sentetik olayla O1 + O4 + O5 + O7 çizer, overlay paneli ve katmanları oluşur; çekirdek devrede değil, event tap ve observer yok) → `tools/bench/out/` |
| `scripts/snapshot.sh [dizin]` | UI render aracı (SPEC §7.1): inert çekirdek, pencere açmaz. Önce SelfTest (`pose(at:)` sözleşmesi: Ease, anahtar pozlar, döngü dikişi, keyTimes, opaklık, overlay path eleman sayısı); sonra davranış regresyonları (aşağıda); sonra Settings sekmeleri, onboarding ekranları (izinli/izinsiz), overlay storyboard kareleri + GIF, menü bar ikonları, durum menüsü (`menu.txt`, `menu-<durum>-<light\|dark>.png`) → `tools/snapshot/out/` |
| `nokta-snapshot --keyboard-test` (snapshot.sh çalıştırır) | Kısayol kaydı ve klavye, gerçek shell kodu + Carbon defterini taklit eden inert çekirdek (`nk_inert_counters`, `nk_inert_set_taken`): K1 Esc (değiştiricili de) iptal + her kısayol tam bir kez geri · K2 ⌫/⌦ temizler · K3 yeni kısayol tek kez bağlanır · K4 kopya → Swap/Cancel, Swap'ta reddedilen kayıt yok · K5 değiştiricisiz/⇧/⌘/sistem kısayolu reddi, F-tuşu ve ⌥ kabul · K6 başka uygulama tutuyorsa önceki geri; açılışta kayıtlı olan korunur · K7 kayıt sürerken hiçbir şey kayıtlı değil (tercih değişimi, VoiceOver, çekirdek yeniden başlatma, Pause) · K8 pencere kapanması / görünümden çıkma tam bir kez geri; key pencere dışında kayıt başlamaz · K9 Tab/⇧Tab odağı listeden sonraya/önceye taşır, geri çekilmez · K10 tuş kimliği ↔ US/Türkçe Q etiketleri, menü aynı · K11 setler ve kayıtlı ayarlar korunur, Restore Defaults önce sorar, VoiceOver varsayılanı bilinçli seçimi ezmez · K12 VoiceOver rol/ad/değer/yardım |
| `nokta-snapshot --recovery-test` (snapshot.sh çalıştırır) | R1 bozuk açılış argümanları kapalı başarısız olur · R2 preview/bench login item, AX istemi ve System Settings'e hiç dokunmaz (onboarding Done dahil; normal açılışta aynı tıklamalar kaydediciye ulaşır) · R3 izin geri alınınca çekirdek durur, geri verilince her kısayol tam bir kez · R4 uyanma/oturum/ekran değişimi yeniden kaydetmez · R5 Pause/Resume · R6 onboarding yalnız ilk açılışta ve izin yokken kendiliğinden açılır |
| `nokta-snapshot --practice-test` (snapshot.sh çalıştırır) | Option-Command seti ve onboarding alıştırması, gerçek AppController + OnboardingWindowController, inert çekirdek; tuşlar alıştırmaya yerel tuş izleyicisinin vereceği biçimde, snap'ler çekirdeğin olayları olarak verilir: P1 ⌥⌘ seti Tiles tuşları, 20 farklı kısayol, ilke geçer, ⌥⌘D Dock'ta kalır, 20 kayıt; Settings ve onboarding'de üç set · P2 Tiles/Spectacle kuruluysa ekran 3 o setle açılır — yalnız dokunulmamış varsayılanda, VoiceOver'ın Alternate'i önce; tuş izleyicisi yalnız ekran 3'te · P3 pencereye ulaşan basışın anlamı (başka set, bilinmeyen, değiştiricisiz, Snapline'ın kendi kısayolu, VoiceOver, alınmış; ⌘W/Tab/Return hiçbir şey) · P4 adım, basılı tuşlar, snap işaretler ve sıradakini söyler, 6 s sonra adıma döner, boşta Restore sayılır, hata nedenini söyler, dördü → bitti; izinsiz kilitli · P5 başka setin alışkanlığı → tek tıkla set, adım izler · P6 başka uygulamanın tuttuğu kısayol satırda (Tiles adıyla); uygulama kapanınca yalnız o kısayol yeniden kaydedilir · P7 tutulan değiştiriciler tuşlarda, rehber döngüsünün dikişi ve pozları · P8 alıştırmadan önce kurulmuş kullanıcıya bir kez, doğrudan ekran 3 |
| `scripts/a11y-audit.sh` | VoiceOver hazırlığı, gerçek sistemde: her onboarding ekranını ve Settings sekmesini `--bench-preview` ile gösterir (kısayol yok, drag snap yok, pencere taşınmaz, geçici tercihler) ve `tools/a11y/axaudit` ile AX ağacını yalnız okuyarak tarar; adı olmayan etkileşimli öğe varsa başarısız. Önce penceresiz bir süreçte denetimin BAŞARISIZ olduğunu doğrular (sıfır öğe asla PASS değil; AX izni yoksa da bu yüzden durur); toplam incelenen öğe sayısını yazar |
| `NOKTA_ALLOW_UNSIGNED_BUILD=1 scripts/build-app.sh` | Yerel ad-hoc build: dev kimliği ve anahtarlığı hiç kullanılmaz (istem olmaz); hardened runtime'lı ad-hoc imza `codesign --verify --strict`'ten geçmek zorunda. Notarize değil, sabit DR yok (Accessibility her build'de yeniden). `NOKTA_BUILD_DIR=build/adhoc` ile ayrı klasöre |
| `NOKTA_BENCH_SESSION=1 scripts/bench.sh` | Ek olarak `--bench-session`: taze idle → menü aç/kapa → Settings ×20 aç/kapa → kısayol iş yükü (flash + etiket) → 300 s kullanım sonrası idle; faz başına 1 Hz `top`/`ps` + faz sınırlarında `vmmap` → `tools/bench/out/session.json` |
| `zig build integrity` | REA ile entitlement/framework/ağ yüzeyi raporu → `docs/INTEGRITY.md`; ihlalde başarısız |

Otomatik testler **hiçbir zaman** global kısayol kaydetmez, sentetik girdi üretmez veya test penceresi dışındaki bir pencereye AX setter çağırmaz (SPEC §7). `--bench-used` yalnız ana ekranın sol alt köşesinde, açılıştan ~2 s içinde, tıklanamaz küçük bir önizleme + bırakma + flash + etiket gösterir; hiçbir pencereyi taşımaz. `scripts/snapshot.sh` hiçbir pencere, panel ya da status item göstermez ve canlı platform sembolü linklemez.

## Manuel (ilk kurulumda ve her release öncesi)
Önkoşul: `zig build app` → `build/Snapline.app` → `/Applications`'a kopyala → aç.
Not: Tiles veya başka bir pencere yöneticisi aynı kısayolları kullanıyorsa Nokta o satırları
"already used" olarak gösterir; testten önce diğerini kapat.

### İzin akışı
- [ ] İlk açılışta onboarding (3 ekran) görünür; ekran 2'de `Open System Settings` Accessibility sayfasını açar.
- [ ] Nokta'yı açınca onboarding kendiliğinden `Access granted.` olur (yeniden başlatmadan): bekleyen kırmızı nokta başlığın noktası olur, 1.8 s sonra ink'e döner; `Continue` varsayılan olur, `Later` gizlenir.
- [ ] Yeni build sonrası izin korunur (sabit imza). Korunmuyorsa: `codesign -d -r- build/Snapline.app` DR'ı kontrol et.
- [ ] İzin varken onboarding'i Later / Esc / ⌘W ile kapat, Nokta'yı yeniden aç: onboarding açılmaz, menüde `Finish Setup…` vardır. İzin yokken yeniden açılış doğrudan izin ekranında (ekran 2) başlar.
- [ ] Nokta çalışırken izni kapatınca ~1 s içinde, menüyü açmadan, menü bar ikonu çapraz çizgili duruma geçer (nokta yok); menünün en üstünde kırmızı noktalı `Allow Accessibility…` çıkar ve onboarding ekran 2'yi açar; bir kısayola basınca `Needs Accessibility` etiketi çıkar. (**P**: `com.apple.accessibility.api` yayını gelmezse en geç kısayol basışında ya da menü açılışında yakalanır.)
- [ ] İzni tekrar açınca ~1 s içinde Nokta kendini yeniden başlatır: ikon Active (dolu yarı + dolu nokta) olur, menüdeki durum yuvası kaybolur, kısayollar ve sürükleme yeniden çalışır (menüyü açmak ya da yeniden başlatmak gerekmez).

### Kısayol kaydı (klavyeyle, Settings › Shortcuts)
- [ ] Tab ile listeye gel, ↓ ile `Left Half`, Space: pill kırmızı noktalı `Type shortcut…` olur; ⌃⌥← artık pencereyi taşımaz (kayıt sürerken Nokta kısayolu yok).
- [ ] Esc: kayıt biter, eski kısayol durur, odak satırda; ⌃⌥← yine çalışır.
- [ ] Space, sonra ⌫: kısayol temizlenir (`—`); Restore Defaults (özel kısayol varken önce sorar) geri getirir.
- [ ] Space, sonra Tab: kayıt biter, odak listenin altındaki kontrole geçer; ⇧Tab yukarıya.
- [ ] Space, sonra A / ⇧A / ⌘A / ⌃↑: satırda neden yazar (`Add ⌃ or ⌥.`, `Apps use ⌘ shortcuts…`, `macOS uses this shortcut.`), kayıt sürer.
- [ ] Space, sonra ⌃⌥→ (Right Half'ın): `Used by “Right Half”.` + Swap/Cancel; Swap sonrası iki kısayol da çalışır.
- [ ] Başka bir uygulama (ör. Rectangle) ⌃⌥X'i tutarken ⌃⌥X kaydet: `⌃⌥X is in use by another app. Kept ⌃⌥←.`, ⌃⌥← çalışmaya devam eder.
- [ ] Kayıt sürerken Settings'i ⌘W ile kapat: kısayollar hemen geri gelir.
- [ ] Türkçe Q'da Alternate set: Next Display satırı ve menü `⌃⇧⌘Ü` gösterir; ⌃⇧⌘Ü çalışır. US düzenine geçince ikisi de `⌃⇧⌘]` olur, kısayol aynı tuşta kalır.

### Kısayollar (Classic set)
- [ ] ⌃⌥←/→/↑/↓ yarılar; aynı yarıya tekrar: ½ → ⅔ → ⅓ → ½; etiket `Left ⅔` görünür.
- [ ] ⌃⌥U/I/J/K çeyrekler; ⌃⌥D/F/G üçte birler; ⌃⌥E/R/T üçte ikiler.
- [ ] ⌃⌥↩ maximize, ⌃⌥⇧↩ almost maximize, ⌃⌥C center, ⌃⌥⌫ restore (snap öncesi çerçeve).
- [ ] İki ekranda ⌃⌥⌘→/←: yarıdaki pencere diğer ekranda da yarı olur.
- [ ] Gap 8 pt: iki yarı arasında tam 8 pt, ekran kenarında dış boşluk ayarı kadar.
- [ ] Alternate set'e geçince ⌃⇧⌘ kombinasyonları çalışır ([ / ] ekranlar, M almost maximize); ⌃⌥ boşalır.
- [ ] VoiceOver açılınca ⌃⌥ kısayolları serbest kalır, menünün durum yuvası `Shortcuts paused for VoiceOver…` der (Settings › Shortcuts'u açar); VO kapanınca geri gelir.
- [ ] Recorder yalnız-⌥ kısayolu kabul eder ama macOS 15.0–15.1 uyarısını gösterir.
- [ ] Sabit boyutlu pencerede (ör. Calculator) bir yarım kısayolu: pencere kenara taşınır, boyutunu korur; etiket `Can't resize` (When needed), sallanma/hata sesi yok. Döşemeden büyük çıkan (min boyutlu) pencerede `Can't get smaller`. Taşınmayı reddeden pencerede `Can't move` (2 s kalır, çerçeve biliniyorsa 1.5 pt dolgusuz çizgi, nokta yok). Nokta'nın kendi (onboarding) penceresinde ilk ikisi görünmez.
- [ ] Menüden bir eylem seç ve menü kapanana kadar başka uygulamaya geç: eylem menü açılmadan önceki uygulamaya gider (`nk_core_perform_pid`), sonraki kısayol yine öndeki uygulamaya.

### Sürükle-bırak
- [ ] Başlık çubuğundan sol kenara sürükle: çizgi, dokunulan kenarın ortasından iki yöne doğru kendini çizer (160 ms) ve karşı kenarda kapanır; bırakınca çizgi kalınlaşır, sağ alt iç köşeye kırmızı nokta konur ve pencere tek adımda oturur. Önizleme sırasında kırmızı yok.
- [ ] Köşeler çeyrek; üst kenar maximize; alt kenar segmentleri üçte birler.
- [ ] ⇧ basılıyken sol kenar → first third; ⇧ bırakılıp fare biraz oynatılınca önizleme yarıya döner.
- [ ] Bölgeler arasında gezinirken çerçeve 140 ms'de yeni hedefe kayar (yeniden çizilmez); aynı anda tek önizleme vardır.
- [ ] Snap'li pencereyi tekrar sürükle: snap öncesi boyutuna döner, imleç pencerede aynı göreli yerde.
- [ ] Bölge dışında bırakınca hiçbir şey olmaz, overlay iptal animasyonuyla söner (120 ms, nokta yok); bölge üstünde bırakınca commit animasyonu (çizgi 3 pt, kırmızı nokta, ≤ 260 ms'de söner). Esc'nin etkisi yok (çekirdek yalnız fareyi dinler).
- [ ] İki ekran arasındaki paylaşılan kenarda bölge tetiklenmez; kenarın komşu ekranla devam etmeyen kısmında (ör. dizüstünün yanından taşan harici ekran alt kenarı) bölge çalışır.
- [ ] Snap'li pencerenin başlığına tıkla (oynatmadan), çift tıkla (zoom) ve hafifçe titret: snap-back OLMAZ, ⌃⌥⌫ hâlâ snap öncesine döner.
- [ ] Sağ yarıdaki pencereyi sol kenarından daralt; alt yarıdakini üst kenarından: snap-back ve önizleme OLMAZ.
- [ ] Sheet'i açık bir pencereyi (ör. kaydet diyaloğu) başlığından sürükle: önizleme ve snap çalışır.
- [ ] Üstü menü çubuğuna dayalı pencereyi (sol yarı ya da Finder'ın varsayılan konumu) yukarı ve biraz yana sürükle: üst bölge (Maximize) önizlemesi çıkar; bırakıp ⌃⌥⌫: pencere eski yerine (aşağı kaymadan) döner. Tamamen dikey sürüklemede pencere hareket etmediği için önizleme çıkmaz (beklenen).
- [ ] ⌘ basılıyken arka plandaki bir pencereyi (uygulamasını öne almadan) kenara sürükle: snap çalışır.
- [ ] Terminal'de ⌃⌥← (hücre ızgarası birkaç pt dar oturur): etiket ÇIKMAZ, ⌃⌥← tekrarları 1/2 → 2/3 → 1/3 döngüsünü sürdürür.
- [ ] Chrome'da metin seçimi ve sayfa kaydırma sırasında Nokta CPU'su ve Chrome yanıtı değişmez (yedek hit-test observer varken çalışmaz).

### Kurallar ve menü
- [ ] Menü "Ignore “App”" sonrası o uygulama öndeyken Nokta kısayolları serbest kalır (uygulamanın kendi ⌃⌥ kısayolları çalışır) ve sürükleme snap yapmaz; başka uygulamaya geçince kısayollar geri gelir.
- [ ] Sol/üst kenardan yeniden boyutlandırma snap ve snap-back tetiklemez.
- [ ] Ignore listesi 64'teyken menüde devre dışı `Ignore list full` satırı görünür.
- [ ] Pause → kısayollar boşalır (başka uygulama aynı kısayolu alabilir), menüde `Resume`, ikon halka noktalı çerçeve; Resume → geri gelir.
- [ ] Her şey yolundayken menüde durum satırı yoktur; eylemler glifleriyle ve kısayollarıyla listelenir (Thirds alt menüsü: First · Middle · Last · First Two · Middle Two · Last Two). Ölçülen sayılar (bellek, son snap, soket) yalnız Settings › About'tadır.
- [ ] Durum yuvası: izin yokken `Allow Accessibility…` (kırmızı nokta), kurulum bitmemişken `Finish Setup…`, VoiceOver ⌃⌥'yı askıdayken `Shortcuts paused for VoiceOver…`, event tap kurulamazsa `Drag snapping unavailable` (tooltip `Drag snapping could not start.`; Settings › About), çekirdek durmuşsa `Nokta stopped…`. Birden çok koşulda yalnız en öncelikli çıkar.

### Dayanıklılık
- [ ] Uyku/uyanma sonrası kısayollar ve sürükleme çalışmaya devam eder.
- [ ] Sistem "Play user interface sound effects" kapatılınca (System Settings › Sound) Nokta'nın sesi de susar, Sound açılınca çalan `ready` sesi de çalmaz. (**P**: hangi domain'e yazıldığı — `com.apple.systemsound` ya da global — cihazda doğrulanır.)
- [ ] Ekran tak/çıkar sonrası bölgeler yeni düzene uyar; o ekrandaki ilk ⌃⌥← flaşı görünür ve ~300 ms içinde tamamen söner (panel ekranda kalmaz).
- [ ] Yanıt vermeyen bir uygulama Nokta'yı en fazla ~0.5 s bekletir, sonra `App didn't respond` etiketiyle devam eder; ona ⌘⇥ ile geçmek Nokta'yı en fazla ~0.25 s bekletir.
- [ ] İlk açılışta yalnız Accessibility istenir; Input Monitoring istemi ÇIKMAZ.
- [ ] Harici ekranda snap'lenen pencere, ekran söküldükten sonra ⌃⌥⌫ ile görünür bir yere döner.

### Erişilebilirlik
- [ ] Reduce Motion: overlay yalnız fade; onboarding sahneleri statik `explainT` pozunda, ekran geçişi 150 ms çapraz geçiş.
- [ ] Reduce Transparency: önizleme dolgusu α .80, hale α .95.
- [ ] Increase Contrast: önizleme çizgisi 3 pt α 1, commit 4 pt, menü bar ikonu 2 pt; açık Settings penceresi ve menü bar ikonu yeniden başlatmadan güncellenir.
- [ ] Differentiate Without Color: overlay noktasına 1.5 pt ink halka eklenir; kırmızının yanında hep metin ya da şekil vardır (`Allow Accessibility…`, `Waiting…`, `over 12 MB target`).
- [ ] Koyu görünüm: Dragging › ZoneMap tutamakları ve ekran çizgisi görünür (ink rengi); menü glifleri okunur.
- [ ] VoiceOver: menü bar öğesi "Nokta" + değer `On` / `Paused` / `Needs Accessibility access`; bölge değişiminde eylem adı duyulur; Settings kontrolleri etiketli; onboarding sahneleri `Replay` yardımıyla image olarak okunur.
- [ ] Full Keyboard Access: Settings ve onboarding tamamen klavyeyle.

## v2 görünüş, hareket ve cihaz doğrulamaları
Önkoşul: yukarıdakiyle aynı build. Bu bölüm DESIGN §17–§18'in cihazda bakılacak kısmıdır; `scripts/snapshot.sh` render'ları yerine geçmez, onları tamamlar.

### Çizim ve geometri
- [ ] **Çizim yönü:** sol kenar, sağ kenar, üst kenar, 4 köşe ve alt segmentler için çizgi, dokunulan noktadan (kenarın ortası; köşede köşe; alt segmentte segmentin altı) iki yöne doğru büyür ve karşı noktada kapanır; yön saat yönündedir.
- [ ] **Önizleme söz verir:** çizginin gösterdiği dikdörtgen, bırakınca pencerenin oturduğu dikdörtgendir (gap ve margin dahil); ⇧ ile alternatif haritada da.
- [ ] **Dikey ekran** (ekranı döndür): üçte birler satır olur; çizginin başlangıç noktası eylemin yönüne göre seçilir; nokta ve plaka kısa kenara göre yerleşir.
- [ ] **Çentikli ekran:** üst bölge kullanılabilir alanın tepesinden başlar; çentik bandında çizgi, nokta ve plaka yok; plaka `visibleFrame` içinde kalır.
- [ ] **Çoklu ekran:** önizleme yalnız imlecin ekranında; diğer ekranın paneli anında gizlenir; karışık DPI'lı iki ekran arasında sürüklerken çizgi iki ekranda da keskin, aynı anda iki önizleme yok.
- [ ] **Nokta:** yalnız commit ve flash'ta çıkar (Ø 8, hedefin sağ alt iç köşesi; kısa kenar < 64 pt ise merkez); iptalde, engellendi durumunda ve önizleme sırasında kırmızı yok.
- [ ] **Her animasyondan sonra** overlay paneli gizlenmiştir (`orderOut`); ekranda iz kalmaz.

### Demolar, döngüler, örtülme
- [ ] **3 tur:** onboarding ekran 2 (izin anahtarı) ve ekran 3 (tuş demosu) en çok 3 kez oynar, sonra `explainT`/`restT` pozunda durur; ekran 1 bir kez oynar, sahneye tıklayınca (ya da Full Keyboard Access'te Space) yeniden.
- [ ] **Örtülme:** onboarding penceresi başka bir pencereyle tamamen örtülünce, küçültülünce, uygulama gizlenince (⌘H) ve ekran uyuyunca demo durur (`top`: Nokta CPU %0); görünür olunca döngülü demolar baştan başlar, ekran 1 yalnız hiç oynamadıysa oynar.
- [ ] **Demo maliyeti:** demo oynarken Nokta CPU ortalaması ≤ %0.5, sonra %0.0 (`top`); ProMotion'da kare hızı 60'ı geçmez.
- [ ] **Ayna modu:** ekran 3'te ilk gerçek snap'ten sonra demo durur; yapılan eylemin segmenti bir kez oynar ve chip'e ✓ gelir.
- [ ] **İzin anı:** ekran 2 görünmüyorken (başka uygulamadayken) izin verilirse sahne, ekran görünür olunca oynar; ekran açıldığında izin zaten varsa granted pozu animasyonsuz çizilir.
- [ ] **Idle:** menü bar ikonu hiçbir zaman hareket etmez ve kırmızı değildir; hiçbir pencere açık değilken Nokta'da timer ya da animasyon yok (idle wakeup 0).

### Kod ve ölçüt denetimleri
- [ ] `grep -rnE "Timer|DispatchSourceTimer|CADisplayLink|CVDisplayLink" app/Sources` yalnız onboarding ekran 2'yi gösterir; `repeatCount` yalnız `Timeline` oynatıcısında ve sonlu.
- [ ] `red` token'ı yalnız DESIGN §4.2'deki R1–R6 kod yollarında kullanılır; bir yüzeyde aynı anda ≤ 1 kırmızı öğe.
- [ ] Toplam görünür metin ≤ 600 kelime (DESIGN §10.2 yöntemi); hiçbir paragraf iki kısa satırı geçmez.
- [ ] `otool -L`'de SwiftUI, WebKit, AVFoundation, Metal yok; `Contents/Resources` içinde font, PNG, GIF yok (yalnız `.icns` ve plist).
- [ ] `--bench-used` footprint ≤ 12 MB; Settings kapanınca ve Onboarding kapanınca controller'lar dealloc olur (`leaks` 0); ikisi de kapalıyken activation policy `.accessory`.

### Cihazda yapılan doğrulamalar (2026-10-16, M3, macOS 26.5, kapak kapalı + BenQ 4K "1920 × 1080" 2x, koyu görünüm)
Bench/preview modlarıyla, yalnız Nokta'nın kendi pencereleri üzerinde; ekran görüntüleri `screencapture -l` ile.
- [x] Sürükleme önizlemesi gerçek ekranda (`--bench-used`): çizgi kenarın ortasından iki yöne büyüyüp kapanıyor; bırakmada kalınlaşma ve kırmızı nokta; flash + `Left ⅔` plakası; plaka tek başına kalınca eski çerçeve geri gelmiyor (OV2-1). 2x'te çizgi keskin.
- [x] Menü bar ikonu Liquid Glass menü barında (açık duvar kağıdı) okunur; menü gerçek çiziminde glifler ve kısayollar doğru. Türkçe-Q klavyede AppKit `⌘,`'i `⌘Ö` olarak gösteriyor (sistemin kısayol yerelleştirmesi, bütün AppKit uygulamalarında aynı).
- [x] Onboarding sahneleri gerçek WindowServer'da oynuyor; sahne C oynarken Nokta CPU %0.0 (animasyon render server'da), sahne B'de ≤ %1.3; turlar bitince %0.0 ve 0 uyanma. WindowServer, Nokta'lı ve Nokta'sız aynı aralıkta (ekrandaki diğer işler nedeniyle %35–44; fark gürültü içinde).
- [x] İzin anı (`--bench-preview onboarding-2-grant`, izin 5 s sonra "gelir"): pencere terminalin altında örtülüyken 1 Hz yedek izni yakaladı, Nokta öne geldi, `Access granted.` anı oynadı, nokta 1.8 s sonra ink'e döndü.
- [x] Clamshell + tek harici ekran: overlay, onboarding, Settings ve gecikme ölçümü bu kurulumda çalıştı (kurulum değişimi sırasında yeniden kurma test edilmedi).
- [x] VoiceOver hazırlığı (`scripts/a11y-audit.sh`): 8 yüzeyde 139 etkileşimli öğenin hepsinin okunan adı var (Shortcuts'taki glifsiz satırların boş görüntüsü düzeltildi).
- [x] Bellek (vmmap): menü bir kez açılınca 11.8 → 19.6 MB ve kalıyor; Settings açıkken 34–52 MB, kapandıktan sonra 33–48 MB kalıyor; onboarding 24 MB, kapandıktan sonra 24 MB. Kalan büyük ölçüde AppKit/macOS 26 kontrollerinin süreç ömrü önbellekleri (SwiftUI tabanlı kontrol iç yapısı, ColorSync tabloları 21 → 42, malloc). Bizim tarafımızdaki sızıntı (kapanan Settings'in sekmeleri ve görünümleri pencereyle birlikte yaşıyordu) içerik kapanışta ayrılarak düzeltildi (−4 MB). Kalıcı çözüm önerisi: Settings ve onboarding'i ayrı, kapanınca biten bir süreçte çalıştırmak (BENCHMARKS not 4).

### 2026-10-19 doğrulamaları (klavye / kurtarma adayı; M3, macOS 26.5, BenQ 4K tek ekran)
- [x] `zig build test` 99/99 (HEAD 98 + inert emülasyon testi) · `check-stubs` OK · `snapshot.sh`: self-test 3228, keyboard-test 157, recovery-test 42, settings 27, onboarding timelines 1970.
- [x] Testler gerçekten yakalıyor: 12 eski davranış tek tek geri getirildi (⇧Tab tuzağı, tek geçişli bağlama, eski commit sırası, odağın listeye geri çekilmesi, ANSI-only etiket, reddedilen kaydın çalışan kısayolu silmesi, preview'da System Settings, VoiceOver'ın bilinçli Classic'i ezmesi, her açılışta onboarding, değiştiricili Esc'nin kaydedilmesi, kayıt sırasında bağlama, key pencere dışında kayıt) — her biri en az bir kontrolü düşürdü.
- [x] recovery-test'teki aralıklı `unowned` çökmesi (12 koşuda 2) test düzeneğindeydi: `settle()` run loop'ta kaynak yokken main kuyruğu boşaltmadan dönüyordu. Düzeltme sonrası 30/30 temiz.
- [x] `scripts/a11y-audit.sh` gerçek sistemde (Terminal AX izinli): 8 yüzey, 139 etkileşimli öğe, 0 isimsiz; sıfır öğeli süreç FAIL sayılıyor.
- [x] `NOKTA_ALLOW_UNSIGNED_BUILD=1` ad-hoc bundle: `codesign --verify --deep --strict` geçer, `flags=0x10002(adhoc,runtime)`, entitlement yok; `spctl` reddeder (notarize değil, beklenen). Yerel bütünlük analizi (REA'sız) PASS: ağ sembolü 0/828.
- [ ] (**UNVERIFIED**, gerçek Carbon kaydı + başka uygulama gerekir) başka uygulamanın tuttuğu kombinasyonda Carbon'un gerçekten `eventHotKeyExistsErr` döndürmesi ve Nokta içi Swap'ın tek geçişte reddedilmesi; testler bunu inert çekirdekteki Carbon emülasyonuyla gösterir.
- [ ] (**UNVERIFIED**) menüde Türkçe Q `İ` (0x27): AppKit key equivalent'ı büyük harfe Türkçe yerel ayarsız çevirirse `I` görünebilir; Settings ve VoiceOver `İ` der.

### 2026-10-20 doğrulamaları (0.4.0: alıştırma ekranı, Option-Command seti, DMG penceresi)
- [x] `zig build test` geçer · `check-stubs` OK · `snapshot.sh`: self-test 3228, keyboard-test 157, recovery-test 43, practice-test 129, settings 27, onboarding timelines 1606 (0.4.1: sahne C yalnız tuşlar — minyatür pencere ve ayna segmentleri kalktı).
- [x] Testler gerçekten yakalıyor: 9 bozma tek tek denendi, 9'u da practice-test'i düşürdü (uygulama kapanınca yeniden bağlamama, ⌘ komutlarını yorumlama, izinsiz alıştırma, ekran 3 dışında kalan tuş izleyicisi, yazılmayan `practiceSeen`, seçilmiş seti ezen tanıdık set, her hatayı sayma, ⌥⌘D'ye düşen üçte birler, boşta devam etmeyen rehber).
- [x] `scripts/a11y-audit.sh` gerçek sistemde: 8 yüzey, 144 etkileşimli öğe, 0 isimsiz.
- [x] Boyut: arm64 842,096 B (≤ 850 kB), bundle 936 kB — BENCHMARKS.md 2026-10-20.
- [x] DMG: `tools/dmg/make-dmg.sh` ad-hoc uygulamayla çalıştı; `.DS_Store` geri okundu (pencere 660 × 400, ikon 128, Snapline (180, 210), Applications (480, 210), gizli `.background.tiff` 1x+2x, hacim ikonu), `hdiutil verify` geçti.
- [ ] (**UNVERIFIED**) DMG penceresinin Finder'daki gerçek görünümü (otomasyonda Finder penceresi açılmadı; önizleme kompoziti scratch'te incelendi) ve Dark Mode'da beyaz dosya adlarının etiket zeminindeki okunurluğu.
- [ ] (**UNVERIFIED**) Gerçek Carbon kısayolunun alıştırma ekranında ✓ alması: sentetik olaylar Carbon kısayollarını tetiklemiyor (bu Mac'te kontrol süreciyle doğrulandı), yol yalnız çekirdek olaylarıyla test edildi. Alıştırma ekranının kendisi kullanıcıya bunu canlı gösterir.

### Açık doğrulamalar (DESIGN §18, **P**)
- [ ] Haptiğin arka plandaki uygulamada çalışması (çalışmıyorsa satır ve kod kaldırılır).
- [ ] `com.apple.accessibility.api` bildiriminin izin değişiminde geldiği.
- [ ] macOS 26'da köşe yarıçapı (12 / 16) ve önizlemenin pencere köşesine oturması.
- [ ] Liquid Glass menü barında ikonun okunurluğu (açık ve koyu duvar kağıdı, Reduce Transparency).
- [ ] 4K ölçekli modlarda (1.5x) çizgi keskinliği.
- [ ] Clamshell + tek harici ekranda yüzeylerin yeniden kurulması.
- [ ] Onboarding demolarında WindowServer yükü (`top`).
- [ ] Gerçek Accessibility panelinin sahne B illüstrasyonuyla tutarlılığı.
- [ ] `com.apple.sound.uiaudio.enabled` domain'i.
- [ ] Alternate set çakışmaları (⌃⇧⌘ kombinasyonları).
