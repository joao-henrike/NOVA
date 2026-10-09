document.addEventListener("DOMContentLoaded",()=>{
  csApplyTheme();
  const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
  let coupon=0;
  const toast=msg=>{const e=$("#toast");e.textContent=msg;e.classList.add("show");clearTimeout(toast.t);toast.t=setTimeout(()=>e.classList.remove("show"),2500)};
  $("#themeButton").onclick=()=>{csToggleTheme();toast(`Tema ${csTheme()==="dark"?"escuro":"claro"} ativado.`)};
  const cart=csCart();
  if(!cart.length){window.location.href="index.html#catalogo";return;}
  function render(){
    const valid=cart.filter(i=>csProduct(i.productId)); csSaveCart(valid);
    $("#summaryItems").innerHTML=valid.map(i=>{const p=csProduct(i.productId);return `<div class="summary-item"><div class="summary-thumb">${csImage(p)}</div><div><strong>${p.name}</strong><small>${i.quantity} × ${csBRL(p.price)}</small></div></div>`}).join("");
    const sub=csCartSubtotal(valid);$("#subtotal").textContent=csBRL(sub);$("#total").textContent=csBRL(Math.max(0,sub-coupon));
  }
  function paymentUI(){
    const method=$('input[name="payment"]:checked')?.value;
    $$(".payment-method").forEach(x=>x.classList.toggle("selected",x.querySelector("input").checked));
    $("#cardFields").hidden=!["credit","debit"].includes(method);
    $("#pixInfo").hidden=method!=="pix";
  }
  $$('input[name="payment"]').forEach(x=>x.onchange=paymentUI);
  $("#applyCoupon").onclick=()=>{const code=$("#coupon").value.trim().toUpperCase();if(code==="CLOUD10"){coupon=csCartSubtotal()*0.1;toast("Cupom CLOUD10 aplicado.");}else{coupon=0;toast("Cupom inválido para esta demonstração.");}render()};
  $("#checkoutForm").onsubmit=e=>{e.preventDefault();const fd=new FormData(e.target);const order={id:"CS-"+Date.now().toString().slice(-8),items:csCart(),customer:Object.fromEntries(fd),payment:fd.get("payment"),total:Math.max(0,csCartSubtotal()-coupon),createdAt:new Date().toISOString()};localStorage.setItem("cloudstart_last_order",JSON.stringify(order));csClearCart();window.location.href="confirmation.html"};
  render();paymentUI();
});