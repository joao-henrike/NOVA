document.addEventListener("DOMContentLoaded",()=>{
  csApplyTheme();
  const $=s=>document.querySelector(s);
  const cart=csCart().filter(item=>csProduct(item.productId));
  const draft=csRead("cloudstart_quote_draft",{});
  const rows=cart.length?cart:(Array.isArray(draft.items)?draft.items:[]);
  $("#quoteMeta").textContent=`Gerado em ${new Intl.DateTimeFormat("pt-BR",{dateStyle:"long"}).format(new Date())} · Referência CS-${Date.now().toString().slice(-6)}`;
  $("#quoteItems").innerHTML=rows.length?rows.map(item=>{const p=csProduct(item.productId);return p?`<tr><td>${csEscape(p.name)}${p.recurring?" <span class=\"quote-muted\">(mensal)</span>":""}</td><td>${Math.max(1,Number(item.quantity)||1)}</td><td>${csBRL(p.price)}</td><td>${csBRL(p.price*Math.max(1,Number(item.quantity)||1))}</td></tr>`:""}).join(""):'<tr><td colspan="4">Nenhum produto no carrinho. Volte ao catálogo e adicione itens para gerar uma proposta.</td></tr>';
  const total=rows.reduce((sum,item)=>{const p=csProduct(item.productId);return sum+(p?p.price*Math.max(1,Number(item.quantity)||1):0)},0);
  $("#quoteTotal").textContent=`Total estimado: ${csBRL(total)}${rows.some(item=>csProduct(item.productId)?.recurring)?" + serviços recorrentes conforme itens":""}`;
  $("#themeButton").onclick=()=>csToggleTheme();$("#printQuote").onclick=()=>window.print();$("#backToShop").onclick=()=>location.href="index.html#catalogo";
});
