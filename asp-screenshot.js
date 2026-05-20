/**
 * Auto-Seedbox-PT (ASP) Screenshot 前端扩展
 * 由 Nginx 动态注入：/asp-screenshot.js
 */
(function () {
  console.log(" [ASP] Screenshot 已加载 (极客UI优化版)");

  const SS_API = "/api/ss";

  const script = document.createElement("script");
  script.src = "/sweetalert2.all.min.js";
  document.head.appendChild(script);

  function getCurrentDir() {
    const path = window.location.pathname.replace(/^\/files/, "");
    return decodeURIComponent(path) || "/";
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    }[c]));
  }

  const copyText = (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }

    const textArea = document.createElement("textarea");
    textArea.value = text;
    textArea.style.position = "fixed";
    textArea.style.opacity = "0";
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();

    return new Promise((res, rej) => {
      document.execCommand("copy") ? res() : rej();
      textArea.remove();
    });
  };

  const isMedia = (file) => file && file.match(
    /\.(mp4|mkv|avi|ts|mts|m2ts|mov|webm|mpg|mpeg|wmv|flv|vob|iso|m4v|mpv|tp|trp|evo|rm|rmvb|asf|ogm|ogv|3gp|f4v|divx)$/i
  );

  function clamp(v, lo, hi, fallback) {
    v = parseInt(v, 10);
    if (!Number.isFinite(v)) return fallback;
    return Math.max(lo, Math.min(hi, v));
  }

  function safeFmt(v) {
    return String(v).toLowerCase() === "png" ? "png" : "jpg";
  }

  async function probeVideo(fullPath) {
    try {
      const r = await fetch(`${SS_API}?file=${encodeURIComponent(fullPath)}&probe=1`, { cache: "no-store" });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j && j.meta) return j.meta;
    } catch (e) { }

    return { width: null, height: null, duration: null };
  }

  let lastRightClickedFile = "";

  document.addEventListener("contextmenu", function (e) {
    const row = e.target.closest(".item");
    if (row) {
      const nameEl = row.querySelector(".name");
      if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
    } else {
      lastRightClickedFile = "";
    }
  }, true);

  document.addEventListener("click", function (e) {
    if (!e.target.closest(".asp-ss-btn-class") && !e.target.closest('.item[aria-selected="true"]')) {
      lastRightClickedFile = "";
    }
  }, true);

  async function promptSettings(fileName) {
    if (typeof Swal === "undefined") {
      alert("界面组件加载中，请稍后重试。");
      return null;
    }

    const fullPath = (getCurrentDir() + "/" + fileName).replace(/\/\//g, "/");

    Swal.fire({
      title: "读取视频信息中...",
      text: "正在探测原始分辨率",
      allowOutsideClick: false,
      allowEscapeKey: false,
      didOpen: () => Swal.showLoading()
    });

    const meta = await probeVideo(fullPath);
    const origW = clamp(meta.width, 320, 3840, 1280);
    const origH = meta.height ? clamp(meta.height, 240, 2160, null) : null;

    const presetWs = [origW, 3840, 2560, 1920, 1280, 960, 720]
      .filter((v, i, a) => a.indexOf(v) === i)
      .filter((v) => v >= 320 && v <= 3840);
    const presetNs = [6, 8, 10, 12, 16];

    const html = `
      <style>
        .asp-ss-panel { text-align:left; color:#111827; }
        .asp-ss-title { font-size:20px; font-weight:800; margin-bottom:12px; }
        .asp-ss-file { padding:10px 12px; border-radius:12px; background:#f3f4f6; color:#374151; word-break:break-all; margin-bottom:10px; }
        .asp-ss-tip { padding:10px 12px; border-radius:12px; background:#eff6ff; color:#1d4ed8; font-weight:700; margin-bottom:16px; }
        .asp-ss-row { margin-top:14px; }
        .asp-ss-label { font-weight:700; margin-bottom:8px; display:flex; justify-content:space-between; align-items:center; }
        .asp-ss-input, .asp-ss-select { width:100%; box-sizing:border-box; padding:10px; border-radius:10px; border:1px solid #d1d5db; background:#fff; color:#111827; }
        .asp-ss-chips { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:8px; }
        .ss-chip { border:1px solid #d1d5db; background:#fff; border-radius:999px; padding:6px 12px; cursor:pointer; user-select:none; }
        .ss-chip.active { border-color:#3b82f6; background:#eff6ff; color:#1d4ed8; font-weight:700; }
        .asp-ss-range { width:100%; }
        .asp-ss-muted { color:#6b7280; font-size:12px; margin-top:6px; }
        .asp-ss-grid { display:grid; grid-template-columns:1fr 1fr; gap:14px; }
      </style>
      <div class="asp-ss-panel">
        <div class="asp-ss-title">截图参数配置</div>
        <div class="asp-ss-file">目标文件：<code>${escapeHtml(fileName)}</code></div>
        <div class="asp-ss-tip">⚡ ${origW}${origH ? "x" + origH : "p"} 源解析度，可选择 JPG / PNG + ZIP 归档</div>

        <div class="asp-ss-row">
          <div class="asp-ss-label">截图数量 (张)</div>
          <div id="ss_n_chips" class="asp-ss-chips">
            ${presetNs.map((n) => `<button type="button" class="ss-chip" data-n="${n}">${n}</button>`).join("")}
          </div>
          <input id="ss_n" class="asp-ss-input" type="number" min="1" max="20" step="1" value="6">
        </div>

        <div class="asp-ss-row">
          <div class="asp-ss-label">横向宽度 (px)</div>
          <div id="ss_w_chips" class="asp-ss-chips">
            ${presetWs.map((w) => `<button type="button" class="ss-chip" data-w="${w}">${w}${w === origW ? "(原)" : ""}</button>`).join("")}
          </div>
          <input id="ss_w" class="asp-ss-input" type="number" min="320" max="3840" step="1" value="${origW}">
        </div>

        <div class="asp-ss-row">
          <div class="asp-ss-label">输出格式</div>
          <select id="ss_fmt" class="asp-ss-select">
            <option value="jpg" selected>JPG（体积小，适合发种）</option>
            <option value="png">PNG（无损，体积较大）</option>
          </select>
          <div class="asp-ss-muted">默认 JPG；需要无损截图时再选择 PNG。</div>
        </div>

        <div class="asp-ss-grid">
          <div class="asp-ss-row">
            <div class="asp-ss-label">智能跳过片头 <span><b id="ss_head_v">5</b>%</span></div>
            <input id="ss_head" class="asp-ss-range" type="range" min="0" max="20" step="1" value="5">
          </div>
          <div class="asp-ss-row">
            <div class="asp-ss-label">智能跳过片尾 <span><b id="ss_tail_v">5</b>%</span></div>
            <input id="ss_tail" class="asp-ss-range" type="range" min="0" max="20" step="1" value="5">
          </div>
        </div>
      </div>
    `;

    const result = await Swal.fire({
      html: html,
      width: "680px",
      background: "#ffffff",
      showCancelButton: true,
      confirmButtonText: " 开始执行截图",
      cancelButtonText: "取消",
      confirmButtonColor: "#3b82f6",
      cancelButtonColor: "#9ca3af",
      allowOutsideClick: true,
      allowEscapeKey: true,
      didOpen: () => {
        const head = document.getElementById("ss_head");
        const tail = document.getElementById("ss_tail");
        const hv = document.getElementById("ss_head_v");
        const tv = document.getElementById("ss_tail_v");
        const nInput = document.getElementById("ss_n");
        const wInput = document.getElementById("ss_w");

        head.addEventListener("input", () => (hv.textContent = head.value));
        tail.addEventListener("input", () => (tv.textContent = tail.value));

        const bindChips = (containerId, inputEl, dataAttr) => {
          const container = document.getElementById(containerId);
          container.addEventListener("click", (e) => {
            const t = e.target.closest(".ss-chip");
            if (!t) return;
            container.querySelectorAll(".ss-chip").forEach((c) => c.classList.remove("active"));
            t.classList.add("active");
            inputEl.value = t.getAttribute(dataAttr);
          });
        };

        bindChips("ss_n_chips", nInput, "data-n");
        bindChips("ss_w_chips", wInput, "data-w");

        document.querySelector('.ss-chip[data-n="6"]')?.classList.add("active");
        document.querySelector(`.ss-chip[data-w="${origW}"]`)?.classList.add("active");
      },
      preConfirm: () => {
        return {
          n: clamp(document.getElementById("ss_n").value, 1, 20, 6),
          width: clamp(document.getElementById("ss_w").value, 320, 3840, origW),
          head: clamp(document.getElementById("ss_head").value, 0, 20, 5),
          tail: clamp(document.getElementById("ss_tail").value, 0, 20, 5),
          fmt: safeFmt(document.getElementById("ss_fmt").value),
          fullPath,
          meta
        };
      }
    });

    return result.isConfirmed ? result.value : null;
  }

  function openScreenshot(fileName) {
    promptSettings(fileName).then((opt) => {
      if (!opt) return;

      Swal.fire({
        title: "截图生成中...",
        html: `正在处理...<br>数量 ${opt.n} | 宽度 ${opt.width} | 格式 ${opt.fmt.toUpperCase()} | 掐头去尾 ${opt.head}% / ${opt.tail}%`,
        allowOutsideClick: false,
        allowEscapeKey: false,
        didOpen: () => Swal.showLoading()
      });

      const url = `${SS_API}?file=${encodeURIComponent(opt.fullPath)}&n=${opt.n}&width=${opt.width}&head=${opt.head}&tail=${opt.tail}&fmt=${opt.fmt}&zip=1`;

      fetch(url, { cache: "no-store" })
        .then(async (r) => {
          const text = await r.text();
          let json = null;

          try {
            json = text ? JSON.parse(text) : {};
          } catch (e) {
            throw new Error(
              `截图服务返回的不是 JSON，HTTP ${r.status}，响应内容：${text.slice(0, 300) || "空响应"}`
            );
          }

          return { ok: r.ok, status: r.status, json };
        })
        .then(({ ok, status, json }) => {
          if (!ok || !json || !json.base || !Array.isArray(json.files) || json.files.length === 0) {
            throw new Error(json && json.error ? json.error : `请求失败 (HTTP ${status})`);
          }

          const base = json.base;
          const imgs = json.files.map((f) => `${base}${f}`);
          const absoluteImgs = imgs.map((u) => new URL(u, window.location.origin).href);
          const allLinksText = absoluteImgs.join("\n");
          const zipUrl = json.zip ? `${base}${json.zip}` : null;

          const html = `
            <div style="text-align:left;">
              <div style="padding:10px 12px;border-radius:12px;background:#f3f4f6;color:#374151;word-break:break-all;margin-bottom:10px;">
                文件：<code>${escapeHtml(fileName)}</code>
              </div>
              <div style="padding:10px 12px;border-radius:12px;background:#eff6ff;color:#1d4ed8;font-weight:700;margin-bottom:14px;">
                参数：${imgs.length}张 / ${opt.width}px / ${opt.fmt.toUpperCase()}
              </div>
              <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;">
                ${imgs.map((u, i) => `
                  <a href="${u}" target="_blank" style="display:block;text-decoration:none;color:#111827;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;background:#fff;">
                    <img src="${u}" alt="截图 ${i + 1}" style="display:block;width:100%;height:auto;">
                    <div style="padding:8px 10px;font-weight:700;text-align:center;">#${i + 1} 点击查看全图</div>
                  </a>
                `).join("")}
              </div>
            </div>
          `;

          Swal.fire({
            title: "截图已生成",
            html: html,
            width: "850px",
            allowOutsideClick: true,
            allowEscapeKey: true,
            showCancelButton: true,
            showDenyButton: !!zipUrl,
            confirmButtonText: " 复制全部链接",
            denyButtonText: " 下载 ZIP 压缩包",
            cancelButtonText: "关闭",
            confirmButtonColor: "#28a745",
            denyButtonColor: "#3085d6",
            cancelButtonColor: "#555",
            preConfirm: () => {
              copyText(allLinksText).then(() => {
                const btn = Swal.getConfirmButton();
                const origText = btn.innerHTML;
                btn.innerHTML = "✅ 复制成功，快去发种！";
                setTimeout(() => { btn.innerHTML = origText; }, 2000);
              }).catch(() => {
                alert("复制失败，请手动处理。");
              });
              return false;
            },
            preDeny: () => {
              if (zipUrl) window.open(zipUrl, "_blank");
              const btn = Swal.getDenyButton();
              const origText = btn.innerHTML;
              btn.innerHTML = "✅ 已在新标签页打开下载";
              setTimeout(() => { btn.innerHTML = origText; }, 2000);
              return false;
            }
          });
        })
        .catch((e) => Swal.fire("截图失败", e.toString(), "error"));
    });
  }

  function getAnchorButton(menu) {
    if (!menu) return null;
    return menu.querySelector([
      'button[aria-label="Info"]',
      'button[title="Info"]',
      'button[aria-label="信息"]',
      'button[title="信息"]',
      'button[aria-label="详情"]',
      'button[title="详情"]'
    ].join(","));
  }

  function getActionMenus() {
    const menus = new Set();

    document.querySelectorAll("#dropdown, .context-menu").forEach((menu) => {
      if (menu && menu.querySelector("button.action")) {
        menus.add(menu);
      }
    });

    document.querySelectorAll([
      'button[aria-label="Info"]',
      'button[title="Info"]',
      'button[aria-label="信息"]',
      'button[title="信息"]',
      'button[aria-label="详情"]',
      'button[title="详情"]'
    ].join(",")).forEach((btn) => {
      if (btn.parentElement) menus.add(btn.parentElement);
    });

    return menus;
  }

  let observerTimer = null;

  const observer = new MutationObserver(() => {
    if (observerTimer) clearTimeout(observerTimer);

    observerTimer = setTimeout(() => {
      let targetFile = "";

      if (lastRightClickedFile) {
        targetFile = lastRightClickedFile;
      } else {
        const selectedRows = document.querySelectorAll('.item[aria-selected="true"], .item.selected');
        if (selectedRows.length === 1) {
          const nameEl = selectedRows[0].querySelector(".name");
          if (nameEl) targetFile = nameEl.innerText.trim();
        }
      }

      const ok = isMedia(targetFile);
      const menus = getActionMenus();

      menus.forEach((menu) => {
        const existingBtn = menu.querySelector(".asp-ss-btn-class");

        if (ok) {
          if (!existingBtn) {
            const btn = document.createElement("button");
            btn.className = "action asp-ss-btn-class";
            btn.setAttribute("title", "Screenshot");
            btn.setAttribute("aria-label", "Screenshot");
            btn.innerHTML = '<span class="material-icons">photo_camera</span><span>Screenshot</span>';
            btn.onclick = function (ev) {
              ev.preventDefault();
              ev.stopPropagation();
              document.body.click();
              openScreenshot(targetFile);
            };

            const miBtn = menu.querySelector(".asp-mi-btn-class");
            if (miBtn) {
              miBtn.insertAdjacentElement("afterend", btn);
            } else {
              const anchorBtn = getAnchorButton(menu);
              if (anchorBtn) {
                anchorBtn.insertAdjacentElement("afterend", btn);
              } else {
                menu.appendChild(btn);
              }
            }
          } else {
            const miBtn = menu.querySelector(".asp-mi-btn-class");
            if (miBtn && existingBtn.previousElementSibling !== miBtn) {
              miBtn.insertAdjacentElement("afterend", existingBtn);
            }
          }
        } else if (existingBtn) {
          existingBtn.remove();
        }
      });
    }, 100);
  });

  observer.observe(document.body, { childList: true, subtree: true });
})();