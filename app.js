document.addEventListener("DOMContentLoaded",()=>{
  csApplyTheme();
  const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
  const state={category:"all",search:"",sort:"relevance",size:"medium"};

  const showToast=(msg)=>{const el=$("#toast");if(!el)return;el.textContent=msg;el.classList.add("show");clearTimeout(showToast.t);showToast.t=setTimeout(()=>el.classList.remove("show"),2400)};
  const updateCount=()=>{const n=csCartCount();$("#cartCount").textContent=n;$("#checkoutLink").classList.toggle("disabled",n===0)};
  const openCart=()=>{renderCart();$("#cartDrawer").classList.add("open");$("#cartDrawer").setAttribute("aria-hidden","false");$("#drawerOverlay").hidden=false;document.body.classList.add("drawer-open")};
  const closeCart=()=>{$("#cartDrawer").classList.remove("open");$("#cartDrawer").setAttribute("aria-hidden","true");$("#drawerOverlay").hidden=true;document.body.classList.remove("drawer-open")};

  function renderCart(){
    const cart=csCart(), box=$("#cartItems");
    if(!cart.length){box.innerHTML='<div class="empty-cart"><div class="empty-icon">C</div><h3>Seu carrinho está vazio</h3><p>Adicione produtos para continuar.</p><a href="#catalogo" class="button primary">Explorar catálogo</a></div>';$("#cartSubtotal").textContent=csBRL(0);return}
    box.innerHTML=cart.map(item=>{
      const p=csProduct(item.productId); if(!p)return "";
      return `<div class="cart-item"><div class="cart-thumb">${csImage(p)}</div><div class="cart-info"><strong>${p.name}</strong><small>${p.recurring?"Recorrente":"Compra única"}</small><div class="cart-line"><b>${csBRL(p.price)}</b><div class="qty"><button data-qty="${p.id}" data-delta="-1">−</button><span>${item.quantity}</span><button data-qty="${p.id}" data-delta="1">+</button></div></div><button class="remove" data-remove="${p.id}">Remover</button></div></div>`
    }).join("");
    $("#cartSubtotal").textContent=csBRL(csCartSubtotal(cart));
    $$("[data-qty]").forEach(b=>b.onclick=()=>{csChangeQuantity(b.dataset.qty,Number(b.dataset.delta));renderCart();updateCount()});
    $$("[data-remove]").forEach(b=>b.onclick=()=>{csRemoveFromCart(b.dataset.remove);renderCart();updateCount();showToast("Produto removido do carrinho.")});
  }

  function filtered(){
    let items=CLOUDSTART_PRODUCTS.filter(p=>(state.category==="all"||p.category===state.category)&&`${p.name} ${p.label} ${p.description}`.toLowerCase().includes(state.search.toLowerCase()));
    if(state.sort==="priceAsc")items.sort((a,b)=>a.price-b.price);
    if(state.sort==="priceDesc")items.sort((a,b)=>b.price-a.price);
    if(state.sort==="name")items.sort((a,b)=>a.name.localeCompare(b.name));
    return items;
  }

  function renderProducts(){
    const items=filtered(), grid=$("#productGrid");
    $("#resultCount").textContent=`${items.length} ${items.length===1?"produto":"produtos"}`;
    $("#resultTitle").textContent=state.search?`Resultados para “${state.search}”`:state.category==="all"?"Soluções em destaque":({"server":"Servidores","network":"Networking","security":"Firewall e segurança","cloud":"Soluções em nuvem","suite":"Suites"}[state.category]||"Catálogo");
    grid.innerHTML=items.length?items.map(p=>{
      const wished=csWishlist().includes(p.id);
      return `<article class="product-card">
        <div class="product-media"><button class="wish ${wished?"active":""}" data-wish="${p.id}" aria-label="Favoritar">${wished?"♥":"♡"}</button>${p.badge?`<span class="badge">${p.badge}</span>`:""}${csImage(p)}<button class="quick" data-quick="${p.id}">Ver detalhes</button></div>
        <div class="product-content"><span class="product-label">${p.label}</span><h3>${p.name}</h3><p>${p.description}</p>
          <div class="specs">${p.specs.slice(0,2).map(s=>`<span>${s}</span>`).join("")}</div>
          <div class="product-buy"><div><strong>${csBRL(p.price)}</strong><small>${p.recurring?"por mês":"à vista demonstrativo"}</small></div><button class="add" data-add="${p.id}">Adicionar</button></div>
        </div>
      </article>`
    }).join(""):'<div class="empty-results"><h3>Nenhum produto encontrado</h3><p>Tente outra busca ou categoria.</p><button class="button secondary" id="clearFilters">Limpar filtros</button></div>';
    $$("[data-add]").forEach(b=>b.onclick=()=>{csAddToCart(b.dataset.add);renderCart();updateCount();showToast("Produto adicionado ao carrinho.");openCart()});
    $$("[data-wish]").forEach(b=>b.onclick=()=>{const active=csToggleWishlist(b.dataset.wish);b.classList.toggle("active",active);b.textContent=active?"♥":"♡";showToast(active?"Adicionado aos favoritos.":"Removido dos favoritos.")});
    $$("[data-quick]").forEach(b=>b.onclick=()=>openQuickview(b.dataset.quick));
    $("#clearFilters")?.addEventListener("click",()=>{state.search="";state.category="all";$("#search").value="";syncCategoryUI();renderProducts()});
  }

  function syncCategoryUI(){$$("#categoryChips .chip").forEach(b=>b.classList.toggle("active",b.dataset.category===state.category));$$(".category-inner a[data-category]").forEach(a=>a.classList.toggle("active",a.dataset.category===state.category))}

  function openQuickview(id){
    const p=csProduct(id); if(!p)return;
    $("#quickviewContent").innerHTML=`<div class="quick-grid"><div class="quick-image">${csImage(p)}</div><div><span class="product-label">${p.label}</span><h2>${p.name}</h2><p>${p.description}</p><div class="quick-price">${csBRL(p.price)} <small>${p.recurring?"por mês":"valor demonstrativo"}</small></div><ul>${p.specs.map(s=>`<li>${s}</li>`).join("")}</ul><button class="button primary full" id="quickAdd">Adicionar ao carrinho</button></div></div>`;
    $("#quickAdd").onclick=()=>{csAddToCart(id);updateCount();renderCart();$("#quickview").hidden=true;showToast("Produto adicionado ao carrinho.");openCart()};
    $("#quickview").hidden=false;
  }

  const sizeInfo={
    small:{title:"Pequena empresa",desc:"Base enxuta para começar com segurança.",items:["1 servidor","1 switch gerenciável","1 firewall","Backup em nuvem"]},
    medium:{title:"Média empresa",desc:"Equilíbrio entre disponibilidade, gestão e crescimento.",items:["2 servidores","2 switches","1 firewall","Cloud + backup"]},
    large:{title:"Grande empresa",desc:"Arquitetura orientada a escala, redundância e governança.",items:["Cluster de servidores","Switching redundante","Segurança avançada","Cloud + monitoramento"]}
  };
  function renderSize(){const x=sizeInfo[state.size];$("#solutionPanel").innerHTML=`<div><span class="eyebrow">RECOMENDAÇÃO</span><h3>${x.title}</h3><p>${x.desc}</p></div><div class="recommend-list">${x.items.map(i=>`<span>${i}</span>`).join("")}</div>`;$$(".size-card").forEach(b=>b.classList.toggle("active",b.dataset.size===state.size))}

  function calculate(){
    const s=Number($("#calcServers").value)||0,sw=Number($("#calcSwitches").value)||0,f=Number($("#calcFirewalls").value)||0,u=Number($("#calcUsers").value)||0,c=Number($("#calcCloud").value)||0;
    const discounts={small:.05,medium:.08,large:.12}, sub=s*18990+sw*8490+f*4890+u*49.9, discount=sub*discounts[state.size], total=sub-discount;
    $("#estimateSubtotal").textContent=csBRL(sub);$("#estimateDiscount").textContent=`-${csBRL(discount)}`;$("#estimateCloud").textContent=csBRL(c);$("#estimateTotal").textContent=csBRL(total);
  }
  function addEstimate(){const values=[["server-r360",Number($("#calcServers").value)||0],["switch-catalyst",Number($("#calcSwitches").value)||0],["firewall-60f",Number($("#calcFirewalls").value)||0],["cloud-pro",$("#calcCloud").value==="0"?0:1]];values.forEach(([id,q])=>{if(q>0)csAddToCart(id,q)});updateCount();renderCart();showToast("Cenário adicionado ao carrinho.");openCart()}

  $("#themeButton").onclick=()=>{csToggleTheme();showToast(`Tema ${csTheme()==="dark"?"escuro":"claro"} ativado.`)};
  $("#cartTrigger").onclick=openCart;$("#cartClose").onclick=closeCart;$("#drawerOverlay").onclick=closeCart;$("#continueShopping").onclick=closeCart;$("#footerCart").onclick=openCart;
  $("#checkoutLink").onclick=e=>{if(!csCart().length){e.preventDefault();showToast("Adicione pelo menos um produto antes do checkout.")}};
  $("#search").oninput=e=>{state.search=e.target.value.trim();renderProducts()};$("#searchButton").onclick=()=>document.querySelector("#catalogo").scrollIntoView({behavior:"smooth"});
  $$("#categoryChips .chip").forEach(b=>b.onclick=()=>{state.category=b.dataset.category;syncCategoryUI();renderProducts();document.querySelector("#catalogo").scrollIntoView({behavior:"smooth"})});
  $$(".category-inner a[data-category]").forEach(a=>a.onclick=()=>{state.category=a.dataset.category;syncCategoryUI();renderProducts()});
  $("#sort").onchange=e=>{state.sort=e.target.value;renderProducts()};
  $$(".size-card").forEach(b=>b.onclick=()=>{state.size=b.dataset.size;renderSize()});
  ["calcServers","calcSwitches","calcFirewalls","calcUsers","calcCloud"].forEach(id=>$("#"+id).oninput=calculate);
  $("#addEstimate").onclick=addEstimate;
  $$("[data-close-quick]").forEach(b=>b.onclick=()=>$("#quickview").hidden=true);
  $("#quickview").addEventListener("click",e=>{if(e.target.id==="quickview")$("#quickview").hidden=true});
  $("#quoteButton").onclick=()=>{window.location.href="mailto:suporte@cloudstart.local?subject=Solicitação%20de%20orçamento%20CloudStart"};
  renderProducts();renderSize();calculate();renderCart();updateCount();
});