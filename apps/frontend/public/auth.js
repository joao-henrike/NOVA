"use strict";
// Real auth in FastAPI is OAuth; do not fake email/password sessions on HTTP.
document.addEventListener("DOMContentLoaded",()=>{
  csApplyTheme();
  document.getElementById("themeButton")?.addEventListener("click",csToggleTheme);
});
