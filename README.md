# El Hareketi Sunum Uygulaması

[desktop-cizim](https://github.com/bekirs01/desktop-cizim) projesi ile entegre. Telefon kamerası ile el hareketlerinizi algılayarak PDF üzerinde çizim yapmanızı sağlar.

## Özellikler

- **Link girişi**: desktop-cizim paylaşım linkini girin
  - Örnek: `https://desktop-cizim-production.up.railway.app/view.html?id=SHARE_TOKEN`
- **Kamera**: Telefon kamerası ile el hareketlerinizi izler
- **El hareketi tanıma**: MediaPipe ile gerçek zamanlı gesture algılama
  - **Pointing_Up** (işaret parmağı yukarı): Çizim modu
  - **Closed_Fist** (yumruk): Silme
  - **Open_Palm** (açık avuç): Hareket (çizim yok)

## Teknoloji

- Kotlin + Jetpack Compose
- CameraX
- MediaPipe Gesture Recognizer
- Navigation Compose

## desktop-cizim Entegrasyonu

Uygulama [desktop-cizim](https://github.com/bekirs01/desktop-cizim) Supabase backend'i ile çalışır:
- **Supabase**: `pdf_page_strokes` tablosu
- **Link formatı**: `view.html?id=SHARE_TOKEN`
- **Stroke formatı**: points (0-1 normalize), color, lineWidth

Supabase URL/KEY değiştirmek için: `SupabaseConfig` (SupabaseClient.kt)

## Kurulum

1. Android Studio ile projeyi açın
2. `./gradlew assembleDebug` ile derleyin veya cihaza yükleyin
3. **Fiziksel cihaz** gerekir (emülatörde kamera sorunlu olabilir)

## Gereksinimler

- Android 7.0+ (API 24)
- Kamera izni
