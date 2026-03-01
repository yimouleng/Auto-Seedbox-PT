
/* Auto-Seedbox-PT: FileBrowser Screenshot Extension (SweetAlert2 UI) */
(function () {
  const SS_API = "/api/ss";
  const SS_WIDTH = 1280;
  const SS_COUNT = 6;

  function getCurrentPath() {
    const h = window.location.hash || "";
    const m = h.match(/^#\/files\/(.*)$/);
    if (!m) return null;
    const raw = m[1].split("?")[0].split("#")[0];
    try { return decodeURIComponent(raw); } catch (e) { return raw; }
  }

  function isProbablyVideo(path) {
    if (!path) return false;
    const lower = path.toLowerCase();
    return /\.(mkv|mp4|m2ts|ts|avi|mov|wmv|flv|webm|mpg|mpeg)$/.test(lower);
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  }

  function ensureButton() {
    const header = document.querySelector("header") || document.querySelector(".header");
    if (!header) return;
    if (document.getElementById("asp-ss-btn")) return;

    const btn = document.createElement("button");
    btn.id = "asp-ss-btn";
    btn.type = "button";
    btn.textContent = "截图";
    btn.title = "为当前视频生成 6 张截图（宽度 1280，存 /tmp）";
    btn.style.cssText = [
      "margin-left:12px",
      "padding:6px 12px",
      "border-radius:12px",
      "border:1px solid rgba(255,255,255,0.14)",
      "background:rgba(0,0,0,0.22)",
      "color:#fff",
      "cursor:pointer",
      "font-weight:700",
      "letter-spacing:.5px",
      "box-shadow: 0 6px 18px rgba(0,0,0,0.18)",
      "backdrop-filter: blur(8px)",
      "transition: transform .08s ease, background .2s ease, box-shadow .2s ease"
    ].join(";");

    btn.onmouseenter = () => { btn.style.background = "rgba(0,0,0,0.32)"; btn.style.boxShadow = "0 10px 26px rgba(0,0,0,0.22)"; };
    btn.onmouseleave = () => { btn.style.background = "rgba(0,0,0,0.22)"; btn.style.boxShadow = "0 6px 18px rgba(0,0,0,0.18)"; };
    btn.onmousedown  = () => { btn.style.transform = "scale(0.98)"; };
    btn.onmouseup    = () => { btn.style.transform = "scale(1)"; };

    btn.addEventListener("click", async () => {
      const path = getCurrentPath();
      if (!window.Swal) { alert("SweetAlert2 未加载，无法展示截图弹窗。"); return; }
      if (!path) {
        Swal.fire({ icon: "info", title: "未检测到文件路径", text: "请先进入一个文件详情页面再截图。" });
        return;
      }

      const qs = new URLSearchParams({ file: path, n: String(SS_COUNT), width: String(SS_WIDTH), fmt: "jpg" });
      const reqUrl = `${SS_API}?${qs.toString()}`;

      if (!isProbablyVideo(path)) {
        const r = await Swal.fire({
          icon: "warning",
          title: "看起来不是常见视频后缀",
          html: `<div style="text-align:left;opacity:.9">路径：<code>${escapeHtml(path)}</code><br/>仍要尝试截图吗？</div>`,
          showCancelButton: true,
          confirmButtonText: "继续截图",
          cancelButtonText: "取消",
          reverseButtons: true
        });
        if (!r.isConfirmed) return;
      }

      Swal.fire({
        title: "正在生成截图…",
        html: `<div style="opacity:.85">默认 6 张 / 宽度 1280 / 输出到 <code>/tmp</code></div>`,
        allowOutsideClick: false,
        allowEscapeKey: false,
        didOpen: () => { Swal.showLoading(); }
      });

      try {
        const res = await fetch(reqUrl, { cache: "no-store" });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || !data || !data.base || !Array.isArray(data.files) || data.files.length === 0) {
          const msg = (data && data.error) ? data.error : `请求失败 (HTTP ${res.status})`;
          throw new Error(msg);
        }

        const base = data.base; // /__asp_ss__/token/
        const imgs = data.files.map(f => `${base}${f}`);

        const grid = `
          <div style="display:grid;grid-template-columns:repeat(2,1fr);gap:12px;margin-top:12px">
            ${imgs.map((u, i) => `
              <a href="${u}" target="_blank" style="text-decoration:none">
                <div style="border-radius:16px;overflow:hidden;border:1px solid rgba(255,255,255,0.12);background:rgba(0,0,0,0.22)">
                  <div style="padding:7px 10px;display:flex;justify-content:space-between;align-items:center">
                    <div style="font-weight:800">#${i+1}</div>
                    <div style="opacity:.7;font-size:12px">新标签打开</div>
                  </div>
                  <img src="${u}" style="width:100%;display:block" loading="lazy" />
                </div>
              </a>
            `).join("")}
          </div>
          <div style="margin-top:10px;opacity:.75;text-align:left;font-size:12px">
            截图存放：<code>/tmp/asp_screens/</code>（会自动清理旧文件）
          </div>
        `;

        Swal.fire({
          icon: "success",
          title: "截图生成完成",
          width: 940,
          html: `<div style="text-align:left"><div style="opacity:.85">文件：<code>${escapeHtml(path)}</code></div>${grid}</div>`,
          confirmButtonText: "好的",
          showCloseButton: true
        });
      } catch (e) {
        Swal.fire({
          icon: "error",
          title: "截图失败",
          html: `<div style="text-align:left;opacity:.9">${escapeHtml(String(e.message || e))}</div>
                 <div style="text-align:left;margin-top:8px;opacity:.7;font-size:12px">
                   可能原因：ffmpeg 不可用 / 文件不可读 / 不是视频 / 反代限制。
                 </div>`,
          confirmButtonText: "知道了",
          showCloseButton: true
        });
      }
    });

    header.appendChild(btn);
  }

  const obs = new MutationObserver(() => ensureButton());
  obs.observe(document.documentElement, { childList: true, subtree: true });
  ensureButton();
})();
