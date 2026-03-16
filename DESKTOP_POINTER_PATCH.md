# desktop-cizim: Lazer İşaretçi (Pointer) Desteği

Mobil uygulama **tek işaret parmağını kaldırdığında** telefon ekranında ve sunum ekranında lazer işaretçi görünür. Parmak takip edilir, sunumda nerede olduğunuzu görebilirsiniz.

## 1. subscribeStrokes callback'ine ekle

`subscribeStrokes(shareId, (payload) => { ... })` içinde, mevcut bloklardan önce veya sonra:

```javascript
// Lazer işaretçi - mobil tek parmakla işaret ettiğinde (işaret parmağı yukarı)
if (payload?.event === "pointer_position") {
  const { x, y } = payload.payload || {};
  if (typeof x === "number" && typeof y === "number") {
    pointerPosition = { x, y };
    requestAnimationFrame(drawPointer);
  }
} else if (payload?.event === "pointer_hidden") {
  pointerPosition = null;
  requestAnimationFrame(drawPointer);
}
```

## 2. pointerPosition ve drawPointer

```javascript
let pointerPosition = null;

function drawPointer() {
  const canvas = document.getElementById("draw-canvas"); // veya PDF çizim canvas'ınız
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  if (pointerPosition) {
    const x = pointerPosition.x * canvas.width;
    const y = pointerPosition.y * canvas.height;
    ctx.save();
    // Glow
    ctx.beginPath();
    ctx.arc(x, y, 14, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(255, 68, 68, 0.35)";
    ctx.fill();
    // Lazer noktası
    ctx.beginPath();
    ctx.arc(x, y, 6, 0, Math.PI * 2);
    ctx.fillStyle = "#FF4444";
    ctx.fill();
    ctx.strokeStyle = "white";
    ctx.lineWidth = 1.5;
    ctx.stroke();
    ctx.restore();
  }
}
```

**Önemli:** `drawStrokesToCanvas` her çağrıldığında sonrasında `drawPointer()` çağrın. Böylece çizimler + pointer birlikte görünür.

## Tıklama (Tap) - Web arayüzünü kontrol

Kullanıcı işaret parmağı ile bir yere işaret edip başparmak+işaret ile pinch yaptığında (kısa dokunuş) = tıklama. Web'de o konuma tıklama simüle edin:

```javascript
if (payload?.event === "tap_at") {
  const { x, y } = payload.payload || {};
  if (typeof x === "number" && typeof y === "number") {
    const canvas = document.getElementById("draw-canvas");
    if (canvas) {
      const rect = canvas.getBoundingClientRect();
      const px = rect.left + x * rect.width;
      const py = rect.top + y * rect.height;
      const ev = new MouseEvent("click", {
        clientX: px,
        clientY: py,
        bubbles: true,
      });
      const el = document.elementFromPoint(px, py);
      if (el) el.dispatchEvent(ev);
    }
  }
}
```

Böylece kullanıcı telefondan renk seçiciye, araçlara, butonlara parmağıyla tıklayabilir.

## drawStrokesToCanvas entegrasyonu

Pointer'ın her zaman görünmesi için, `drawStrokesToCanvas` fonksiyonunun **sonuna** şunu ekleyin:

```javascript
function drawStrokesToCanvas(w, h) {
  // ... mevcut stroke çizim kodu ...
  drawPointer();  // Pointer'ı en üstte göster
}
```

## Realtime mesaj formatı

Mobil uygulama şu event'leri broadcast eder:
- `pointer_position`: `{ pageNum, x, y }` - normalize [0,1], lazer konumu (işaret parmağı yukarı)
- `pointer_hidden`: `{ pageNum }` - işaretçiyi gizle
- `tap_at`: `{ pageNum, x, y }` - normalize [0,1], tıklama konumu (pinch ile)

**Payload yapısı:** `payload.event` ve `payload.payload` (x, y, pageNum)
