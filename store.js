/* CloudStart Commerce V7 - shared catalog, cart and theme state */
const CLOUDSTART_PRODUCTS = [
  {
    id:"server-r360", name:"Dell PowerEdge R360", category:"server", label:"Servidor",
    price:21998, recurring:false, badge:"Mais vendido",
    description:"Servidor rack 1U para virtualização, aplicações corporativas e workloads críticos.",
    image:"https://www.dell.com/cdn-cgi/image/width=1200,quality=85,format=webp/https://i.dell.com/is/image/DellContent/content/dam/images/products/servers/poweredge/r360/media-gallery/server-poweredge-r360-gallery-1.psd",
    fallback:"assets/images/server.svg", specs:["Intel Xeon","Até 128 GB ECC","Rack 1U","Ideal para virtualização"]
  },
  {
    id:"server-r260", name:"Dell PowerEdge R260", category:"server", label:"Servidor",
    price:17999, recurring:false, badge:"Entrada corporativa",
    description:"Servidor rack 1U compacto para filiais, aplicações e infraestrutura de entrada.",
    image:"https://www.tnc.com.vn/uploads/product/sp2026/ext/server-dell-poweredge-r260-xeon-6315p-6x2-5-r260-625-16g1-2t-171336.webp",
    fallback:"assets/images/server.svg", specs:["Rack 1U","ECC","Gestão remota","Workloads corporativos"]
  },
  {
    id:"switch-catalyst", name:"Cisco Catalyst 9200", category:"network", label:"Switch",
    price:8490, recurring:false, badge:"Corporativo",
    description:"Switch gerenciável para redes corporativas com foco em segurança e disponibilidade.",
    image:"https://www.cisco.com/c/dam/en/us/products/collateral/switches/catalyst-9200-series-switches/nb-06-cat9200-series-switches-900x600.jpg",
    fallback:"assets/images/network.svg", specs:["24 portas","Gerenciável","PoE+","Recursos corporativos"]
  },
  {
    id:"switch-us24", name:"Ubiquiti UniFi Switch 24", category:"network", label:"Switch",
    price:2299, recurring:false, badge:"Custo-benefício",
    description:"Switch Layer 2 de 24 portas para pequenas e médias empresas.",
    image:"https://cdn.ecomm.ui.com/products/fc8d2e53-536f-4de4-834c-dd945260404c/21e3eb26-150f-4c1b-9c0d-ae6cb765a377.png",
    fallback:"assets/images/network.svg", specs:["24 portas Gigabit","2 SFP","Layer 2","Fanless"]
  },
  {
    id:"firewall-60f", name:"FortiGate 60F", category:"security", label:"Firewall",
    price:13365, recurring:false, badge:"Segurança",
    description:"NGFW compacto para proteção de rede, VPN, SD-WAN e controle de tráfego.",
    image:"https://www.avfirewalls.com/images/fortinet/fortigate-60f-large.jpg",
    fallback:"assets/images/firewall.svg", specs:["NGFW","VPN","SD-WAN","IPS/IDS"]
  },
  {
    id:"u6-plus", name:"Ubiquiti UniFi U6+", category:"network", label:"Wi-Fi 6",
    price:1099, recurring:false, badge:"Wi-Fi",
    description:"Access point Wi-Fi 6 para escritórios e ambientes corporativos.",
    image:"https://cdn.ecomm.ui.com/products/6d5c6141-e2e9-416a-b789-53e59416bb1a/fe055e16-62dc-408f-844e-a76053e63f0d.png",
    fallback:"assets/images/network.svg", specs:["Wi-Fi 6","PoE","UniFi","Alta densidade"]
  },
  {
    id:"cloud-pro", name:"CloudStart Cloud Pro", category:"cloud", label:"Solução em nuvem",
    price:399, recurring:true, badge:"Recorrente",
    description:"Ambiente cloud gerenciado para aplicações, monitoramento e expansão.",
    image:"https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/cloud.svg", specs:["Monitoramento","Backup","Escalabilidade","AWS-ready"]
  },
  {
    id:"backup-1tb", name:"Cloud Backup 1 TB", category:"cloud", label:"Backup",
    price:89, recurring:true, badge:"Continuidade",
    description:"Backup em nuvem para dados críticos e recuperação operacional.",
    image:"https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/cloud.svg", specs:["1 TB","Retenção","Criptografia","Relatórios"]
  },
  {
    id:"business-suite", name:"CloudStart Business Suite", category:"suite", label:"Suite",
    price:49.90, recurring:true, badge:"Produtividade",
    description:"Suite de serviços para operação, produtividade e gestão de infraestrutura.",
    image:"https://images.unsplash.com/photo-1556761175-b413da4baf72?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/suite.svg", specs:["Gestão","Produtividade","Serviços recorrentes","Painel"]
  },
  {
    id:"security-suite", name:"Security Suite Pro", category:"suite", label:"Suite",
    price:79.90, recurring:true, badge:"Proteção",
    description:"Camada de segurança para endpoints, acesso e monitoramento.",
    image:"https://images.unsplash.com/photo-1563013544-824ae1b704d3?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/suite.svg", specs:["Endpoints","Acesso","Monitoramento","Relatórios"]
  }
];

const CS_KEYS = Object.freeze({cart:"cloudstart_cart_v7",theme:"cloudstart_theme_v7",wishlist:"cloudstart_wishlist_v7"});

function csProduct(id){ return CLOUDSTART_PRODUCTS.find(p=>p.id===id); }
function csBRL(value){ return new Intl.NumberFormat("pt-BR",{style:"currency",currency:"BRL"}).format(value); }
function csRead(key,fallback){ try{return JSON.parse(localStorage.getItem(key) || JSON.stringify(fallback));}catch{return fallback;} }
function csCart(){ const data=csRead(CS_KEYS.cart,[]); return Array.isArray(data)?data:[]; }
function csSaveCart(cart){ localStorage.setItem(CS_KEYS.cart,JSON.stringify(cart)); }
function csCartCount(cart=csCart()){ return cart.reduce((sum,item)=>sum + Math.max(0,Number(item.quantity)||0),0); }
function csCartSubtotal(cart=csCart()){ return cart.reduce((sum,item)=>{const p=csProduct(item.productId);return sum+(p?p.price*(Number(item.quantity)||0):0)},0); }
function csAddToCart(id,quantity=1){
  const product=csProduct(id); if(!product) return false;
  const cart=csCart(); const item=cart.find(x=>x.productId===id);
  if(item) item.quantity += quantity; else cart.push({productId:id,quantity});
  csSaveCart(cart); return true;
}
function csChangeQuantity(id,delta){
  const cart=csCart(); const item=cart.find(x=>x.productId===id); if(!item) return;
  item.quantity += delta;
  csSaveCart(cart.filter(x=>x.quantity>0));
}
function csRemoveFromCart(id){ csSaveCart(csCart().filter(x=>x.productId!==id)); }
function csClearCart(){ csSaveCart([]); }
function csTheme(){ return localStorage.getItem(CS_KEYS.theme) || "light"; }
function csSetTheme(theme){ localStorage.setItem(CS_KEYS.theme,theme); document.documentElement.dataset.theme=theme; }
function csToggleTheme(){ csSetTheme(csTheme()==="dark"?"light":"dark"); }
function csApplyTheme(){ csSetTheme(csTheme()); }
function csWishlist(){ const data=csRead(CS_KEYS.wishlist,[]); return Array.isArray(data)?data:[]; }
function csToggleWishlist(id){
  const list=csWishlist(); const index=list.indexOf(id);
  if(index>=0) list.splice(index,1); else list.push(id);
  localStorage.setItem(CS_KEYS.wishlist,JSON.stringify(list)); return list.includes(id);
}
function csEscape(value){ return String(value).replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[char])); }
function csImage(product){
  return `<img src="${product.image}" alt="${csEscape(product.name)}" loading="lazy" onerror="this.onerror=null;this.src='${product.fallback}'">`;
}
