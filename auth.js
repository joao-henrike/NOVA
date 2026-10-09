document.addEventListener("DOMContentLoaded",()=>{
  csApplyTheme();
  const $=s=>document.querySelector(s);
  $("#themeButton").onclick=()=>csToggleTheme();
  const toast=msg=>{const e=$("#toast");e.textContent=msg;e.classList.add("show");clearTimeout(toast.t);toast.t=setTimeout(()=>e.classList.remove("show"),2300)};
  $("#googleButton").onclick=()=>{localStorage.setItem("cloudstart_demo_user",JSON.stringify({provider:"google",name:"Conta Google"}));toast("Google conectado no modo demonstrativo.");setTimeout(()=>location.href="index.html",700)};
  $("#loginForm")?.addEventListener("submit",e=>{e.preventDefault();const fd=new FormData(e.target);localStorage.setItem("cloudstart_demo_user",JSON.stringify({email:fd.get("email"),name:fd.get("email").split("@")[0]}));toast("Login demonstrativo realizado.");setTimeout(()=>location.href="index.html",700)});
  $("#registerForm")?.addEventListener("submit",e=>{e.preventDefault();const fd=new FormData(e.target);localStorage.setItem("cloudstart_demo_user",JSON.stringify({email:fd.get("email"),name:fd.get("name"),company:fd.get("company")}));toast("Conta criada no modo demonstrativo.");setTimeout(()=>location.href="index.html",700)});
});