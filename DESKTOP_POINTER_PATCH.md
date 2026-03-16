# desktop-cizim: Lazer İşaretçi (Pointer) Desteği

Mobil uygulama tek işaret parmağı ile işaret ettiğinde, sunum ekranında lazer noktası gösterilir.

## subscribeStrokes callback'ine ekle

`subscribeStrokes(shareId, (payload) => { ... })` içinde, mevcut `if (payload?.type === "progress")` bloklarından önce veya sonra:

```javascript
// Lazer işaretçi - mobil tek parmakla işaret ettiğinde
if (payload?.event === "pointer_position") {
  const { x, y } = payload.payload || {};
  if (typeof x === "number" && typeof y === "number") {
    pointerPosition = { x, y };
    drawPointer();
  }
} else if (payload?.event === "pointer_hidden") {
  pointerPosition = null;
  drawPointer();
}
```

## pointerPosition ve drawPointer

```javascript
let pointerPosition = null;

function drawPointer() {
  const canvas = document.getElementById("draw-canvas"); // veya PDF çizim canvas'ınız
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  // Önceki pointer'ı temizle (veya double-buffer kullan)
  // Basit yöntem: her frame'de tüm çizimleri yeniden çiz + pointer
  if (pointerPosition) {
    const x = pointerPosition.x * canvas.width;
    const y = pointerPosition.y * canvas.height;
    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, 8, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(255, 0, 0, 0.6)";
    ctx.fill();
    ctx.strokeStyle = "red";
    ctx.lineWidth = 3;
    ctx.stroke();
    ctx.restore();
  }
}
```

`drawStrokesToCanvas` çağrıldıktan sonra `drawPointer()` çağrın. Veya requestAnimationFrame ile sürekli çizim döngüsünde pointer'ı çizin.

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

## Realtime mesaj formatı

Mobil uygulama şu event'leri broadcast eder:
- `pointer_position`: `{ pageNum, x, y }` - normalize [0,1], lazer konumu
- `pointer_hidden`: `{ pageNum }` - işaretçiyi gizle
- `tap_at`: `{ pageNum, x, y }` - normalize [0,1], tıklama konumu (pinch ile)
