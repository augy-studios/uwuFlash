/* QR codes for the share sheet. The encoder is loaded on demand from the
   same CDN as PeerJS, only once somebody starts sharing, which needs the
   network anyway. The markup is drawn here rather than by the library, so
   the quiet zone and the colours are ours. */

const QR_URL = "https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js";

// Four modules of margin is what the QR standard asks for. A scanner finds
// the code by that empty border, so it is never trimmed to save space.
const QUIET_ZONE = 4;

let loading = null;

function loadEncoder() {
  if (window.qrcode) return Promise.resolve(window.qrcode);
  if (loading) return loading;

  loading = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = QR_URL;
    script.async = true;
    script.onload = () =>
      window.qrcode ? resolve(window.qrcode) : reject(new Error("QR encoder did not load"));
    script.onerror = () => {
      script.remove();
      loading = null;
      reject(new Error("Could not load the QR encoder"));
    };
    document.head.appendChild(script);
  });

  return loading;
}

/* An <svg> string for `text`. Rejects when the encoder cannot be loaded; the
   code and the link are shown either way, so the caller just leaves the QR
   out. */
export async function qrSvg(text) {
  const qrcode = await loadEncoder();
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();

  const count = qr.getModuleCount();
  const size = count + QUIET_ZONE * 2;
  let path = "";
  for (let row = 0; row < count; row++) {
    for (let col = 0; col < count; col++) {
      if (qr.isDark(row, col)) path += `M${col + QUIET_ZONE} ${row + QUIET_ZONE}h1v1h-1z`;
    }
  }

  return `<svg class="qr" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges" role="img" aria-label="QR code for the join link">
    <rect class="qr-light" width="${size}" height="${size}"/>
    <path class="qr-dark" d="${path}"/>
  </svg>`;
}
