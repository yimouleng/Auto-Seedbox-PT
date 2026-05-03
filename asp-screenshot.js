/**
 * Auto-Seedbox-PT (ASP) Screenshot 前端扩展
 * 由 Nginx 动态注入：/asp-screenshot.js
 */
(function () {
    console.log("📸 [ASP] Screenshot 已加载 (极客UI优化版)");

    const SS_API = "/api/ss";

    const script = document.createElement("script");
    script.src = "/sweetalert2.all.min.js";
    document.head.appendChild(script);

    function getCurrentDir() {
        const path = window.location.pathname.replace(/^\/files/, "");
        return decodeURIComponent(path) || "/";
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
    }

    const copyText = (text) => {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        } else {
            let textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.opacity = "0";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            return new Promise((res, rej) => {
                document.execCommand('copy') ? res() : rej();
                textArea.remove();
            });
        }
    };

    const isMedia = (file) => file && file.match(
  /\.(mp4|mkv|avi|ts|mts|m2ts|mov|webm|mpg|mpeg|wmv|flv|vob|iso|m4v|mpv|tp|trp|evo|rm|rmvb|asf|ogm|ogv|3gp|f4v|divx)$/i
);
    function clamp(v, lo, hi, fallback) {
        v = parseInt(v, 10);
        if (!Number.isFinite(v)) return fallback;
        return Math.max(lo, Math.min(hi, v));
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
                .ss-wrap { text-align: left; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; color: #1f2937; }
                .ss-head { margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px dashed #e5e7eb; }
                .ss-title { font-size: 18px; font-weight: 600; color: #111827; margin-bottom: 8px; display: flex; align-items: center; gap: 8px; }
                .ss-sub { font-size: 13px; color: #6b7280; margin-bottom: 12px; display: flex; align-items: center; }
                .ss-sub code { font-family: 'Consolas', monospace; background: #f3f4f6; border: 1px solid #e5e7eb; border-radius: 4px; padding: 2px 6px; color: #ec4899; margin-left: 8px; word-break: break-all; }
                .ss-meta { display: flex; gap: 10px; flex-wrap: wrap; }
                .ss-pill { font-size: 12px; font-family: 'Consolas', monospace; background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 6px; padding: 4px 10px; color: #1d4ed8; display: inline-flex; align-items: center; }
                .ss-pill.fmt { background: #f0fdf4; color: #15803d; border-color: #bbf7d0; }
                .ss-form { display: grid; grid-template-columns: 130px 1fr; gap: 20px 16px; align-items: start; }
                .ss-form label { font-size: 14px; font-weight: 600; color: #374151; padding-top: 6px; }
                .ss-control { display: flex; flex-direction: column; gap: 10px; }
                .ss-input-box { display: flex; align-items: center; position: relative; }
                .ss-form input[type='number'] { width: 100%; padding: 8px 12px; border-radius: 6px; border: 1px solid #d1d5db; background: #fff; color: #111827; outline: none; font-family: 'Consolas', monospace; font-size: 14px; transition: all 0.2s ease; box-shadow: inset 0 1px 2px rgba(0,0,0,0.02); }
                .ss-form input[type='number']:focus { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15), inset 0 1px 2px rgba(0,0,0,0.02); }
                .ss-chip-row { display: flex; gap: 8px; flex-wrap: wrap; }
                .ss-chip { cursor: pointer; padding: 5px 12px; border-radius: 20px; border: 1px solid #d1d5db; background: #fff; color: #4b5563; font-size: 12px; font-family: 'Consolas', monospace; user-select: none; transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); }
                .ss-chip:hover { border-color: #9ca3af; background: #f9fafb; }
                .ss-chip.active { background: #eff6ff; border-color: #60a5fa; color: #1d4ed8; font-weight: 600; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }
                .ss-range-wrap { display: flex; align-items: center; gap: 12px; }
                .ss-form input[type='range'] { -webkit-appearance: none; width: 100%; background: transparent; height: 24px; margin: 0; outline: none; }
                .ss-form input[type='range']::-webkit-slider-runnable-track { width: 100%; height: 6px; background: #e5e7eb; border-radius: 3px; }
                .ss-form input[type='range']::-webkit-slider-thumb { -webkit-appearance: none; height: 16px; width: 16px; border-radius: 50%; background: #3b82f6; cursor: pointer; margin-top: -5px; box-shadow: 0 2px 4px rgba(0,0,0,0.15); transition: transform 0.1s; }
                .ss-form input[type='range']::-webkit-slider-thumb:hover { transform: scale(1.15); background: #2563eb; }
                .ss-val { display: inline-flex; justify-content: center; align-items: center; min-width: 44px; background: #f3f4f6; border: 1px solid #e5e7eb; border-radius: 6px; padding: 4px 6px; color: #374151; font-family: 'Consolas', monospace; font-size: 12px; font-weight: bold; }
                @media (max-width:760px) { .ss-form { grid-template-columns: 1fr; gap: 12px; } }
            </style>

            <div class='ss-wrap'>
                <div class='ss-head'>
                    <div class='ss-title'>
                        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>
                        截图参数配置
                    </div>
                    <div class='ss-sub'>目标文件 <code>${escapeHtml(fileName)}</code></div>
                    <div class='ss-meta'>
                        <span class='ss-pill'>⚡ ${origW}${origH ? "x" + origH : "p"} 源解析度</span>
                        <span class='ss-pill fmt'>📦 JPG + ZIP 归档</span>
                    </div>
                </div>

                <div class='ss-form'>
                    <label>截图数量 (张)</label>
                    <div class='ss-control'>
                        <div class='ss-input-box'><input id='ss_n' type='number' min='1' max='20' value='6'/></div>
                        <div class='ss-chip-row' id='ss_n_chips'>
                            ${presetNs.map((n) => `<span class='ss-chip' data-n='${n}'>${n}</span>`).join("")}
                        </div>
                    </div>

                    <label>横向宽度 (px)</label>
                    <div class='ss-control'>
                        <div class='ss-input-box'><input id='ss_w' type='number' min='320' max='3840' value='${origW}'/></div>
                        <div class='ss-chip-row' id='ss_w_chips'>
                            ${presetWs.map((w) => `<span class='ss-chip' data-w='${w}'>${w}${w === origW ? "(原)" : ""}</span>`).join("")}
                        </div>
                    </div>

                    <label>智能跳过片头</label>
                    <div class='ss-control'>
                        <div class='ss-range-wrap'>
                            <input id='ss_head' type='range' min='0' max='20' value='5'/>
                            <div class='ss-val'><span id='ss_head_v'>5</span>%</div>
                        </div>
                    </div>

                    <label>智能跳过片尾</label>
                    <div class='ss-control'>
                        <div class='ss-range-wrap'>
                            <input id='ss_tail' type='range' min='0' max='20' value='5'/>
                            <div class='ss-val'><span id='ss_tail_v'>5</span>%</div>
                        </div>
                    </div>
                </div>
            </div>
        `;

        const result = await Swal.fire({
            html: html,
            width: '680px',
            background: '#ffffff',
            showCancelButton: true,
            confirmButtonText: "🚀 开始执行截图",
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

                head.addEventListener("input", () => (hv.textContent = head.value));
                tail.addEventListener("input", () => (tv.textContent = tail.value));

                const nInput = document.getElementById("ss_n");
                const wInput = document.getElementById("ss_w");

                const bindChips = (containerId, inputEl, dataAttr) => {
                    const container = document.getElementById(containerId);
                    container.addEventListener("click", (e) => {
                        const t = e.target.closest(".ss-chip");
                        if (!t) return;
                        container.querySelectorAll('.ss-chip').forEach(c => c.classList.remove('active'));
                        t.classList.add('active');
                        inputEl.value = t.getAttribute(dataAttr);
                    });
                };

                bindChips("ss_n_chips", nInput, "data-n");
                bindChips("ss_w_chips", wInput, "data-w");

                document.querySelector(`.ss-chip[data-n="6"]`)?.classList.add('active');
                document.querySelector(`.ss-chip[data-w="${origW}"]`)?.classList.add('active');
            },
            preConfirm: () => {
                return {
                    n: clamp(document.getElementById("ss_n").value, 1, 20, 6),
                    width: clamp(document.getElementById("ss_w").value, 320, 3840, origW),
                    head: clamp(document.getElementById("ss_head").value, 0, 20, 5),
                    tail: clamp(document.getElementById("ss_tail").value, 0, 20, 5),
                    fullPath, meta
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
                html: `正在处理...<br><br><span style="font-size:13px;color:#aaa;">数量 <b>${opt.n}</b> | 宽度 <b>${opt.width}</b> | 掐头去尾 <b>${opt.head}% / ${opt.tail}%</b></span>`,
                allowOutsideClick: false,
                allowEscapeKey: false,
                didOpen: () => Swal.showLoading()
            });

            const url = `${SS_API}?file=${encodeURIComponent(opt.fullPath)}&n=${opt.n}&width=${opt.width}&head=${opt.head}&tail=${opt.tail}&fmt=jpg&zip=1`;

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

                    let html = `
                        <style>
                            .ss-panel { background:#1e1e1e; color:#d4d4d4; font-family:'Consolas', monospace; font-size:13px; text-align:left; border-radius:8px; padding:15px; }
                            .ss-top { margin-bottom:12px; line-height:1.6; }
                            .ss-top code { background:#2d2d2d; border:1px solid #444; border-radius:4px; padding:2px 6px; color:#ce9178; word-break:break-all; }
                            .ss-grid-wrap { max-height:500px; overflow-y:auto; padding-right:5px; margin-bottom:15px; }
                            .ss-grid { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:12px; }
                            .ss-card { border:1px solid #3c3c3c; border-radius:6px; overflow:hidden; background:#252526; transition: 0.2s; }
                            .ss-card:hover { border-color: #569cd6; }
                            .ss-bar { padding:6px 10px; display:flex; justify-content:space-between; align-items:center; font-size:12px; background:#2d2d2d; color:#9cdcfe; border-bottom:1px solid #3c3c3c; }
                            .ss-idx { font-weight:bold; color:#dcdcaa; }
                            .ss-img { display:block; width:100%; max-height:220px; object-fit:cover; background:#111; }
                            @media (max-width:760px) { .ss-grid { grid-template-columns:1fr; } }
                        </style>
                        <div class='ss-panel'>
                            <div class='ss-top'>
                                文件：<code>${escapeHtml(fileName)}</code><br>
                                参数：<span style="color:#4ec9b0;">${imgs.length}张 / ${opt.width}px</span>
                            </div>
                            <div class='ss-grid-wrap'>
                                <div class='ss-grid'>
                                    ${imgs.map((u, i) => `
                                    <a href='${u}' target='_blank' style='text-decoration:none'>
                                        <div class='ss-card'>
                                            <div class='ss-bar'><span class='ss-idx'>#${i + 1}</span><span>点击查看全图</span></div>
                                            <img class='ss-img' src='${u}' loading='lazy' />
                                        </div>
                                    </a>`).join("")}
                                </div>
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
                        confirmButtonText: "📋 复制全部链接",
                        denyButtonText: "📦 下载 ZIP 压缩包",
                        cancelButtonText: "关闭",
                        confirmButtonColor: "#28a745",
                        denyButtonColor: "#3085d6",
                        cancelButtonColor: "#555",
                        preConfirm: () => {
                            copyText(allLinksText).then(() => {
                                let btn = Swal.getConfirmButton();
                                let origText = btn.innerHTML;
                                btn.innerHTML = '✅ 复制成功，快去发种！';
                                setTimeout(() => { btn.innerHTML = origText; }, 2000);
                            }).catch(() => {
                                alert("复制失败，请手动处理。");
                            });
                            return false;
                        },
                        preDeny: () => {
                            if (zipUrl) window.open(zipUrl, "_blank");
                            let btn = Swal.getDenyButton();
                            let origText = btn.innerHTML;
                            btn.innerHTML = '✅ 已在新标签页打开下载';
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
        ].join(','));
    }

    function getActionMenus() {
        const menus = new Set();

        document.querySelectorAll('#dropdown, .context-menu').forEach((menu) => {
            if (menu && menu.querySelector('button.action')) {
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
        ].join(',')).forEach((btn) => {
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
                        btn.innerHTML = '<i class="material-icons">photo_camera</i><span>Screenshot</span>';

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
