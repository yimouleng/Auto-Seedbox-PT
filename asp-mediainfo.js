/**
 * Auto-Seedbox-PT (ASP) MediaInfo 极客前端扩展
 * 由 Nginx 底层动态注入
 */
(function() {
    console.log("🚀 [ASP] MediaInfo v1.1 已加载 (优化 PT 发种体验)！");
    
    // 兼容剪贴板复制逻辑
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

    // 动态引入弹窗 UI 库
    const script = document.createElement('script');
    script.src = "/sweetalert2.all.min.js";
    document.head.appendChild(script);

    function getCurrentPath() {
        let path = window.location.pathname.replace(/^\/files/, '');
        return decodeURIComponent(path) || '/';
    }

    let lastRightClickedFile = "";

    // 捕获右键选中目标
    document.addEventListener('contextmenu', function(e) {
        let row = e.target.closest('.item');
        if (row) {
            let nameEl = row.querySelector('.name');
            if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
        } else {
            lastRightClickedFile = "";
        }
    }, true);

    // 左键点击任意非按钮区域，清空右键记忆，防止幽灵状态
    document.addEventListener('click', function(e) {
        if (!e.target.closest('.asp-mi-btn-class') && !e.target.closest('.item[aria-selected="true"]')) {
            lastRightClickedFile = "";
        }
    }, true);

    const openMediaInfo = (fileName) => {
        let fullPath = (getCurrentPath() + '/' + fileName).replace(/\/\//g, '/');
        if (typeof Swal === 'undefined') {
            alert('UI组件正在加载，请稍后再试...'); return;
        }
        Swal.fire({
            title: '解析中...',
            text: '正在读取底层媒体轨道信息',
            allowOutsideClick: false,
            didOpen: () => Swal.showLoading()
        });
        
        fetch(`/api/mi?file=${encodeURIComponent(fullPath)}`)
        .then(r => r.json())
        .then(data => {
            if(data.error) throw new Error(data.error);
            
            let rawText = "";
            let html = `<style>
                .mi-box { text-align:left; font-size:13px; background:#1e1e1e; color:#d4d4d4; padding:15px; border-radius:8px; max-height:550px; overflow-y:auto; font-family: 'Consolas', 'Courier New', monospace; user-select:text;}
                .mi-track { margin-bottom: 20px; }
                .mi-track-header { font-size: 15px; font-weight: bold; margin-bottom: 8px; padding-bottom: 4px; border-bottom: 1px solid #444; }
                .mi-Video .mi-track-header { color: #569cd6; border-bottom-color: #569cd6; }
                .mi-Audio .mi-track-header { color: #4ec9b0; border-bottom-color: #4ec9b0; }
                .mi-Text .mi-track-header { color: #ce9178; border-bottom-color: #ce9178; }
                .mi-General .mi-track-header { color: #dcdcaa; border-bottom-color: #dcdcaa; }
                .mi-Menu .mi-track-header { color: #c586c0; border-bottom-color: #c586c0; }
                .mi-item { display: flex; padding: 3px 0; line-height: 1.5; border-bottom: 1px dashed #333;}
                .mi-key { width: 180px; flex-shrink: 0; color: #9cdcfe; }
                .mi-val { flex-grow: 1; color: #cecece; word-wrap: break-word; }
            </style><div class="mi-box">`;

            if (data.media && data.media.track) {
                data.media.track.forEach(t => {
                    let type = t['@type'] || 'Unknown';
                    rawText += `${type}\n`;
                    html += `<div class="mi-track mi-${type}"><div class="mi-track-header">${type}</div>`;

                    for (let k in t) { 
                        if (k === '@type') continue;
                        let val = t[k];
                        if (typeof val === 'object') val = JSON.stringify(val);
                        
                        let paddedKey = String(k).padEnd(32, ' ');
                        rawText += `${paddedKey}: ${val}\n`;

                        html += `<div class="mi-item"><div class="mi-key">${k}</div><div class="mi-val">${val}</div></div>`;
                    }
                    rawText += `\n`;
                    html += `</div>`;
                });
            } else { 
                rawText = JSON.stringify(data, null, 2); 
                html += `<pre>${rawText}</pre>`;
            }
            html += `</div>`;
            
            Swal.fire({ 
                title: fileName, 
                html: html, 
                width: '850px',
                showCancelButton: true,
                showDenyButton: true,
                confirmButtonColor: '#3085d6',
                denyButtonColor: '#28a745',
                cancelButtonColor: '#555',
                confirmButtonText: '📋 纯文本',
                denyButtonText: '🏷️ 复制 BBCode',
                cancelButtonText: '关闭',
                preConfirm: () => {
                    let textToCopy = rawText.trim();
                    copyText(textToCopy).then(() => {
                        let btn = Swal.getConfirmButton();
                        let originalText = btn.innerHTML;
                        btn.innerHTML = '✅ 纯文本复制成功！';
                        setTimeout(() => { btn.innerHTML = originalText; }, 2000);
                    }).catch(() => {
                        alert('复制失败，请手动选中上方文本进行复制');
                    });
                    return false;
                },
                preDeny: () => {
                    let textToCopy = `[quote]\n${rawText.trim()}\n[/quote]`;
                    copyText(textToCopy).then(() => {
                        let btn = Swal.getDenyButton();
                        let originalText = btn.innerHTML;
                        btn.innerHTML = '✅ BBCode 复制成功！';
                        setTimeout(() => { btn.innerHTML = originalText; }, 2000);
                    }).catch(() => {
                        alert('复制失败，请手动选中上方文本进行复制');
                    });
                    return false;
                }
            });
        }).catch(e => Swal.fire('解析失败', e.toString(), 'error'));
    };

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
                let selectedRows = document.querySelectorAll('.item[aria-selected="true"], .item.selected');
                if (selectedRows.length === 1) {
                    let nameEl = selectedRows[0].querySelector('.name');
                    if (nameEl) targetFile = nameEl.innerText.trim();
                }
            }

            let isMedia = targetFile && targetFile.match(/\.(mp4|mkv|avi|ts|iso|rmvb|wmv|flv|mov|webm|vob|m2ts|bdmv|flac|wav|ape|alac)$/i);

            let menus = getActionMenus();

            menus.forEach(menu => {
                let existingBtn = menu.querySelector('.asp-mi-btn-class');
                if (isMedia) {
                    if (!existingBtn) {
                        let btn = document.createElement('button');
                        btn.className = 'action asp-mi-btn-class';
                        btn.setAttribute('title', 'MediaInfo');
                        btn.setAttribute('aria-label', 'MediaInfo');
                        btn.innerHTML = '<i class="material-icons">movie</i><span>MediaInfo</span>';
                        
                        btn.onclick = function(ev) {
                            ev.preventDefault();
                            ev.stopPropagation();
                            document.body.click(); 
                            openMediaInfo(targetFile);
                        };
                        
                        let anchorBtn = getAnchorButton(menu);
                        if (anchorBtn) {
                            anchorBtn.insertAdjacentElement('afterend', btn);
                        } else {
                            menu.appendChild(btn);
                        }
                    }
                } else {
                    if (existingBtn) existingBtn.remove();
                }
            });
        }, 100);
    });

    observer.observe(document.body, { childList: true, subtree: true });
})();
