# Mirror's Edge (2008) — Nativni iOS / iPadOS Port (Statička rekompilacija + Metal)

Nativni iOS i iPadOS port igre **Mirror's Edge (2008)** zasnovan na projektu [`macMirror`](https://github.com) autora *captain-courageous* (statička rekompilacija x86 koda u C + nativni Direct3D 9 na Apple Metal sloj).

Portovano, memorijski optimizovano i prilagođeno za iOS/iPadOS uz **Apple Liquid Glass Xbox One virtuelni kontroler** — **vrkutak** (`://vrkutak.com`).

> **Gotov LITE `.ipa` dostupan za preuzimanje:** Spreman za instalaciju **LITE `.ipa`** (bez ikakvih zaštićenih fajlova igre) nalazi se u sekciji **[GitHub Releases](../../releases)**. Za detaljno uputstvo za kompajliranje od nule pogledajte **[BUILD.md](BUILD.md)**.

> **Napomena o autorskim pravima:** Ovaj repozitorijum sadrži **isključivo** izvorni kod runtime-a, Metal renderera, virtuelnog kontrolera i build skripti. **Zaštićeni fajlovi igre (`GameData`, `pc-deps`, `.exe` i ikonice) nisu uključeni.** Potrebna je vaša legalna PC kopija igre *Mirror's Edge*.

---

## Glavne mogućnosti

* **100% Nativno izvršavanje (bez JIT-a):** Radi na standardnim (non-jailbreak) iPhone i iPad uređajima preko običnog sideload-a (AltStore, SideStore, Sideloadly) ili LiveContainer-a na zakucanih **60 FPS**.
* **Podrška za sve Apple Silicon čipove (A12 – A19 Pro):**
  * Hardverska BC1–BC5 kompresija tekstura na **A17 Pro / A18 / A19 Pro** (Apple GPU Family 9+).
  * Softverski **BC1/BC2/BC3/BC4/BC5 (DXT1/DXT3/DXT5/3Dc) → RGBA8 dekoder u realnom vremenu** sa automatskim `RGBA8Unorm_sRGB` prikazom za **A12 – A16 Bionic** uređaje (Apple GPU Family 8 i stariji, uključujući iPad A16).
* **Adaptivni memorijski profili (zaštita od iOS Jetsam rušenja):**
  * Pri pokretanju automatski čita fizički RAM uređaja (`hw.memsize`).
  * **≤ 6.5 GB RAM profil** (iPad A16, iPhone 11–14, A12/A13 uređaji): Ograničava prijavljeni D3D9 GPU VRAM na `512 MB`, rezervaciju virtuelne memorije na `2.25 GB`, postavlja UE3 `TextureStreaming|PoolSize=160`, `MaxShadowResolution=512`, `MaxAnisotropy=4` i `1280x888` početnu rezoluciju.
  * **> 6.5 GB RAM profil** (iPhone 15 Pro / 16 Pro / 17 Pro Max, iPad Air/Pro sa M-čipovima): Visoka rezolucija (`0.75x` interna Retina skala), `1024 MB` VRAM limit, puni detalji.
* **Pravi Hor+ Ultrawide prikaz:** Uključuje `ME_PC_FILL_SCREEN=1` i dodaje 19.5:9 rezolucije (`2868x1320`, `2560x1180`, `1920x884`, `1600x736`) direktno u *Video Settings* meni igre.
* **Zakucavanje na Performance (P) jezgra:** Glavna nit igre koristi `QOS_CLASS_USER_INTERACTIVE` prioritet.
* **Apple Liquid Glass Xbox One virtuelni kontroler (`ios_virtual_pad.mm`):**
  * **Dva režima upravljanja:** Brzo prebacivanje između **Twin-Stick** (dve analogne palice) i **Touch-Drag** (leva palica za kretanje + direktno okretanje kamere prevlačenjem prsta po desnoj polovini ekrana).
  * **Nevidljivi Floating Left Stick:** Pojavljuje se tačno ispod prsta gde god dodirnete levu polovinu ekrana i nestaje čim pustite prst.
  * **Auto-Sprint (`LS` klik posle 1s):** Držanje levog analoga do ivice (>88%) duže od 1.0 sekunde automatski aktivira sprint uz vibraciju.
  * **Customize Layout Editor:** Drag & Drop pomeranje i pojedinačna promena veličine svakog dugmeta sa automatskim čuvanjem rasporeda (`NSUserDefaults`).
  * **Gornje ikonice:** Simetrična dugmad **Touch** (podešavanja) i **Hide / Show** (sakrivanje kontrola).

---

## Tehnička specifikacija i rešeni problemi

* **Detaljna tehnička analiza svih problema i rešenja:** Pogledajte **[TROUBLESHOOTING_AND_POSTMORTEM.md](TROUBLESHOOTING_AND_POSTMORTEM.md)**.


| Problem | Uzrok na iOS / iPadOS platformi | Implementirano rešenje |
| :--- | :--- | :--- |
| **Trenutni pad na iPad A16 (`MTLReportFailure` u `createMetalTexture`)** | Apple GPU Family 8 (**A16 Bionic** i stariji) na iOS-u ne podržava `MTLPixelFormatBC1..BC5` u hardveru (uvedeno tek od A17 Pro). | Napisan C++ softverski **BC1–BC5 → RGBA8** dekoder u `mtl_resources.mm` koji se automatski aktivira kada `![device supportsBCTextureCompression]` i prebacuje sRGB pogled na `MTLPixelFormatRGBA8Unorm_sRGB`. |
| **iOS Jetsam rušenje zbog RAM-a na 4–6 GB uređajima** | iOS nema swap za igre i gasi proces ako zauzme previše RAM-a ili ako `mmap` rezerviše svih 4 GB (`0x100000000`) virtuelnog prostora. | Ograničena `mmap` rezervacija na `2.25 GB` (`0x90000000`) za ≤ 6.5 GB uređaje, VRAM prijavljen kao `512 MB`, i ograničen UE3 `PoolSize=160`. |
| **Igra stoji pre prvog frejma (`Present=0`)** | Nit za `SplashScreenClass` (`0x1014`) čekala je u `GetMessageW` jer lažni `HWND` nije imao `owner = self_tid()`, pa nije primala `WM_CLOSE`. | Dodeljen `windows[i].owner = self_tid()` u `rt_host_macos.c` kako bi `PostMessageW` zatvorio splash i pozvao `PostQuitMessage(0)`. |
| **Prekoračenje steka glavne niti** | iOS podrazumevani stek glavne niti je `1 MB`, premalo za 185.000 rekompajliranih funkcija. | Dodat `-Wl,-stack_size,0x4000000` (64 MB stek) u `CMakeLists.txt`. |
| **Zagušenje CPU-a na `Sleep(0)`** | `RenderingThread` je vrteo `QueryPerformanceCounter` + `Sleep(0)` 135 miliona puta u 10s bez popuštanja jezgra. | Uključeno `ME_PC_SLEEP0=1` (`sched_yield()`) i `ME_PC_CPUS=4`. |
| **Konflikt dodira ekrana i miša** | SDL3 pretvara dodire prstom u pokrete miša i ometa XInput kontrole. | Isključeno preko `SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0")`. |
| **Nestanak kontrola iza Metal slike** | `SDL_Metal_CreateView` postavlja novi sloj iznad postojećih dugmića. | Pozvan `ios_vpad_attach_to_window()` direktno nakon `SDL_Metal_CreateView` u `mtl_d3d9_device.mm`. |
| **Mali prozor na iPadOS-u (`820x590`)** | Bez `UIDeviceFamily` u `Info.plist`, iPadOS 26 pokreće aplikaciju u iPhone prozoru. | Dodat `UIDeviceFamily` (`1` i `2`) i `UILaunchScreen` u `Info.plist`. |

---

## Uputstvo za kompajliranje od nule (macOS)

### Preduslovi
1. **macOS** sa instaliranim **Xcode**-om (iOS SDK 15.0+), **CMake**-om (`brew install cmake`) i **Python 3**.
2. **SDL3 za iOS** (`arm64` biblioteke i headeri).
3. **Legalna PC kopija igre Mirror's Edge (2008)** iz koje se uzimaju `mirrorsedge.exe`, DLL fajlovi (za generisanje `lifted/` C koda prema uputstvu originalnog `macMirror` repozitorijuma), kao i folderi `GameData/` i `pc-deps/`.

### Kompajliranje `.ipa` paketa
Pokreni ugrađenu skriptu `build_ios_port.sh`:

* **Samo LITE `.ipa` (~55 MB — `GameData` i `pc-deps` se naknadno kopiraju u *Files* aplikaciju):**
  ```bash
  chmod +x build_ios_port.sh
  ./build_ios_port.sh
  ```
* **I LITE i FULL `.ipa` (~3.9 GB — svi fajlovi igre spakovani unutra):**
  ```bash
  ./build_ios_port.sh /putanja/do/foldera_sa_GameData_i_pc-deps
  ```

Gotovi `.ipa` fajlovi se kreiraju u `~/Downloads/`.

---

## Napomena o korišćenju AI alata (AI Disclaimer)

Delovi adaptacije za iOS/iPadOS platformu, analize logova i otklanjanja grešaka, softverskog BC1–BC5 dekodera tekstura, memorijskih profila, UIKit Liquid Glass virtuelnog kontrolera i build skripti razvijeni su uz pomoć veštačke inteligencije (Google Gemini), pod vođstvom, testiranjem i verifikacijom na stvarnim uređajima od strane **vrkutak** (`://vrkutak.com`).
