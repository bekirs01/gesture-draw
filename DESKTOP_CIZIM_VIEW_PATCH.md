# desktop-cizim view.js için Gerçek Zamanlı Güncelleme

Mobil uygulama (benim_app1) kamera ile çizim yaptığında, PDF görüntüleyici (view.html) anında güncellenmiyor.

**Çözüm:** `view.js` dosyasına `subscribeStrokes` ekleyerek mobil çizimlerin anında PDF üzerinde görünmesini sağla.

---

## 1. view.js dosyasında import'u güncelle

**Eski:**
```javascript
import { fetchStrokesLegacy } from "./supabase-strokes.js";
```

**Yeni:**
```javascript
import { fetchStrokesLegacy, subscribeStrokes } from "./supabase-strokes.js";
```

---

## 2. allStrokes'ı legacy formatına çeviren yardımcı fonksiyon ekle

`drawStrokesToCanvas` fonksiyonundan hemen sonra ekle:

```javascript
/** pdf_page_strokes formatından legacy formatına dönüştür */
function legacyFromStrokes(pageNum, strokes) {
  if (!strokes || !Array.isArray(strokes)) return [];
  return strokes.map((s) => ({ page_num: pageNum, stroke_data: s }));
}
```

---

## 3. İlk yükleme sonrası subscribeStrokes ekle

`allStrokes = (await fetchStrokesLegacy(shareId)) || [];` satırından sonra, `hideLoading()` ve `await renderPage()` çağrılarından önce ekle:

```javascript
allStrokes = (await fetchStrokesLegacy(shareId)) || [];

// Mobil uygulama çizimlerini anında göster
subscribeStrokes(shareId, (payload) => {
  if (payload?.type === "progress") {
    const { pageNum, stroke } = payload;
    if (pageNum != null && stroke?.points?.length >= 2) {
      const progress = legacyFromStrokes(pageNum, [stroke]);
      const others = allStrokes.filter((r) => r.page_num !== pageNum);
      allStrokes = [...others, ...progress];
      if (currentPage === pageNum) drawStrokesToCanvas(drawCanvas?.width || 0, drawCanvas?.height || 0);
    }
  } else if (payload?.new?.strokes) {
    const pageNum = payload.new.page_num;
    const strokes = payload.new.strokes || [];
    const others = allStrokes.filter((r) => r.page_num !== pageNum);
    allStrokes = [...others, ...legacyFromStrokes(pageNum, strokes)];
    if (currentPage === pageNum) drawStrokesToCanvas(drawCanvas?.width || 0, drawCanvas?.height || 0);
  } else if (payload?.eventType === "UPDATE" || payload?.eventType === "INSERT") {
    fetchStrokesLegacy(shareId).then((fresh) => {
      allStrokes = fresh || [];
      drawStrokesToCanvas(drawCanvas?.width || 0, drawCanvas?.height || 0);
    });
  }
});

hideLoading();
await renderPage();
```

---

## Link formatı

Mobil uygulamada girilen link formatı `desktop-cizim` ile uyumlu olmalı:

- **Örnek:** `https://your-site.com/view.html?id=SHARE_TOKEN`
- **Veya:** `https://your-site.com/index.html?id=SHARE_TOKEN`

`id` parametresi = `share_token` (PDF'in paylaşım kimliği)

---

## Akış özeti

1. **desktop-cizim:** PDF yükle → `view.html?id=SHARE_TOKEN` ile paylaş
2. **Mobil:** Linki gir → Kamera aç → Başparmak+İşaret = Çiz, İşaret+Orta = Sil
3. **Supabase:** `pdf_page_strokes` tablosuna yazılır + Realtime broadcast
4. **desktop-cizim:** `subscribeStrokes` ile anlık güncelleme alır → PDF üzerinde çizim görünür
