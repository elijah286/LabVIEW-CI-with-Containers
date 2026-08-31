(() => {
  "use strict";
  const config = window.LVCI || {};
  const root = String(config.pagesUrl || ".").replace(/\/$/, "") || ".";
  const mount = () => {
    if (document.getElementById("lvci-gitlab-header")) return;
    const header = document.createElement("header");
    header.id = "lvci-gitlab-header";
    header.innerHTML = `<a href="${root}/">LabVIEW CI</a><span>${config.repo || "GitLab project"}</span>`;
    header.style.cssText = "display:flex;gap:12px;align-items:center;padding:10px 16px;background:#073b4c;color:#fff;font:14px Georgia,serif";
    const link = header.querySelector("a");
    link.style.cssText = "color:#fff;font-weight:bold;text-decoration:none";
    document.body.insertBefore(header, document.body.firstChild);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount, { once: true });
  else mount();
})();