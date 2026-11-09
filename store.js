/* CloudStart Commerce V7 - shared catalog, cart and theme state */
const CLOUDSTART_PRODUCTS = [
  {
    id:"server-r360", brand:"Dell Technologies", model:"PowerEdge R360", sku:"R360", name:"Dell PowerEdge R360", category:"server", label:"Servidor rack 1U",
    price:28990, recurring:false, badge:"Linha corporativa", priceBasis:"Estimativa de mercado para configuração corporativa de entrada; varia conforme CPU, memória, discos e suporte.",
    description:"Servidor rack 1U para aplicações empresariais, virtualização leve, arquivos e serviços de infraestrutura.",
    image:"https://www.dell.com/cdn-cgi/image/width=1200,quality=85,format=webp/https://i.dell.com/is/image/DellContent/content/dam/images/products/servers/poweredge/r360/media-gallery/server-poweredge-r360-gallery-1.psd",
    fallback:"assets/images/server.svg", specs:["Intel Xeon série E","Memória ECC","Rack 1U","iDRAC remoto"]
  },
  {
    id:"server-r260", brand:"Dell Technologies", model:"PowerEdge R260", sku:"R260", name:"Dell PowerEdge R260", category:"server", label:"Servidor rack 1U",
    price:21990, recurring:false, badge:"Formato compacto", priceBasis:"Estimativa para configuração de entrada; processador, memória, discos e suporte alteram o preço.",
    description:"Servidor rack 1U compacto para filiais, aplicações internas e serviços essenciais de infraestrutura.",
    image:"https://www.tnc.com.vn/uploads/product/sp2026/ext/server-dell-poweredge-r260-xeon-6315p-6x2-5-r260-625-16g1-2t-171336.webp",
    fallback:"assets/images/server.svg", specs:["Intel Xeon série E","Memória ECC","Rack 1U","Gerenciamento remoto"]
  },
  {
    id:"hpe-dl360-gen11", brand:"HPE", model:"ProLiant DL360 Gen11", sku:"DL360 Gen11", name:"HPE ProLiant DL360 Gen11", category:"server", label:"Servidor rack 1U",
    price:52990, recurring:false, badge:"Alta disponibilidade", priceBasis:"Referência de varejo nacional para DL360 Gen11; configuração e garantia alteram o valor.",
    description:"Servidor 1U para virtualização, bancos de dados e aplicações de missão crítica em ambientes corporativos.",
    image:"https://www.hpe.com/content/dam/hpe/shared-publishing/images/product/servers/proliant/dl360-gen11/hpe-proliant-dl360-gen11-front.png",
    fallback:"assets/images/server.svg", specs:["Intel Xeon Scalable","DDR5 ECC","Rack 1U","Fontes redundantes"]
  },
  {
    id:"switch-catalyst", brand:"Cisco", model:"Catalyst C9200L-24T-4G", sku:"C9200L-24T-4G", name:"Cisco Catalyst 9200L 24 portas", category:"network", label:"Switch gerenciável",
    price:18800, recurring:false, badge:"Enterprise", priceBasis:"Referência nacional de revenda para Catalyst 9200L; licenças, PoE e uplinks mudam o preço.",
    description:"Switch de acesso corporativo com gerenciamento centralizado, recursos Layer 3 e opções de uplink para redes empresariais.",
    image:"https://www.cisco.com/c/dam/en/us/products/collateral/switches/catalyst-9200-series-switches/nb-06-cat9200-series-switches-900x600.jpg",
    fallback:"assets/images/network.svg", specs:["24 portas Gigabit","4 uplinks SFP","Layer 3","Gerenciamento corporativo"]
  },
  {
    id:"mikrotik-crs326", brand:"MikroTik", model:"CRS326-24G-2S+RM", sku:"CRS326-24G-2S+RM", name:"MikroTik Cloud Router Switch CRS326", category:"network", label:"Switch rack 1U",
    price:2190, recurring:false, badge:"Custo-benefício", priceBasis:"Estimativa em reais baseada no preço sugerido oficial de US$ 209 e referências de revenda; câmbio e impostos variam.",
    description:"Switch rackmount de 24 portas Gigabit com duas interfaces SFP+ de 10 Gb e RouterOS ou SwOS.",
    image:"https://cdn.mikrotik.com/web-assets/product_files/CRS326-24G-2SplusRM_211044.png",
    fallback:"assets/images/network.svg", specs:["24 portas Gigabit","2 portas SFP+ 10G","RouterOS / SwOS","Rack 1U"]
  },
  {
    id:"firewall-60f", brand:"Fortinet", model:"FortiGate 60F", sku:"FG-60F", name:"Fortinet FortiGate 60F", category:"security", label:"Firewall NGFW",
    price:10990, recurring:false, badge:"Segurança de rede", priceBasis:"Estimativa para appliance; licenças FortiGuard/FortiCare e prazo de suporte podem elevar o investimento.",
    description:"Appliance de segurança com firewall de próxima geração, VPN e SD-WAN para filiais e pequenas/médias empresas.",
    image:"https://www.avfirewalls.com/images/fortinet/fortigate-60f-large.jpg",
    fallback:"assets/images/firewall.svg", specs:["NGFW","VPN IPsec / SSL","SD-WAN","FortiOS"]
  },
  {
    id:"switch-us24", brand:"Ubiquiti", model:"UniFi Switch 24", sku:"USW-24", name:"Ubiquiti UniFi Switch 24", category:"network", label:"Switch gerenciável",
    price:2299, recurring:false, badge:"Pequenas empresas", priceBasis:"Estimativa de revenda nacional; disponibilidade e versão PoE alteram o preço.",
    description:"Switch Layer 2 de 24 portas para escritórios e redes de pequeno e médio porte.",
    image:"https://cdn.ecomm.ui.com/products/fc8d2e53-536f-4de4-834c-dd945260404c/21e3eb26-150f-4c1b-9c0d-ae6cb765a377.png",
    fallback:"assets/images/network.svg", specs:["24 portas Gigabit","2 SFP","UniFi Network","Montagem em rack"]
  },
  {
    id:"u6-plus", brand:"Ubiquiti", model:"UniFi U6+", sku:"U6+", name:"Ubiquiti UniFi U6+", category:"network", label:"Access point Wi-Fi 6",
    price:1099, recurring:false, badge:"Wi-Fi corporativo", priceBasis:"Estimativa de varejo nacional; fonte PoE e condições de importação podem variar.",
    description:"Ponto de acesso Wi-Fi 6 para escritórios, salas de reunião e ambientes com múltiplos dispositivos.",
    image:"https://cdn.ecomm.ui.com/products/6d5c6141-e2e9-416a-b789-53e59416bb1a/fe055e16-62dc-408f-844e-a76053e63f0d.png",
    fallback:"assets/images/network.svg", specs:["Wi-Fi 6","PoE","Gerenciamento UniFi","Dual band"]
  },
  {
    id:"cloud-pro", brand:"CloudStart", model:"Cloud Pro", sku:"CS-CLOUD-PRO", name:"CloudStart Cloud Pro", category:"cloud", label:"Solução em nuvem",
    price:399, recurring:true, badge:"Serviço mensal", priceBasis:"Mensalidade demonstrativa para prototipação; dimensionamento depende de consumo e SLA.",
    description:"Ambiente cloud gerenciado para aplicações, monitoramento e expansão da infraestrutura.",
    image:"https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/cloud.svg", specs:["Monitoramento","Backup","Escalabilidade","AWS-ready"]
  },
  {
    id:"backup-1tb", brand:"CloudStart", model:"Cloud Backup 1 TB", sku:"CS-BACKUP-1TB", name:"Cloud Backup 1 TB", category:"cloud", label:"Backup gerenciado",
    price:89, recurring:true, badge:"Serviço mensal", priceBasis:"Mensalidade demonstrativa; retenção, tráfego e recuperação podem alterar o custo.",
    description:"Backup em nuvem para proteção de dados e recuperação operacional.",
    image:"https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/cloud.svg", specs:["1 TB","Retenção configurável","Criptografia","Relatórios"]
  },
  {
    id:"business-suite", brand:"CloudStart", model:"Business Suite", sku:"CS-BUSINESS", name:"CloudStart Business Suite", category:"suite", label:"Suite empresarial",
    price:49.90, recurring:true, badge:"Por usuário / mês", priceBasis:"Valor demonstrativo por usuário; módulos e licenciamento serão definidos comercialmente.",
    description:"Conjunto de serviços para produtividade, gestão e operação de infraestrutura.",
    image:"https://images.unsplash.com/photo-1556761175-b413da4baf72?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/suite.svg", specs:["Gestão","Produtividade","Serviços recorrentes","Painel"]
  },
  {
    id:"security-suite", brand:"CloudStart", model:"Security Suite Pro", sku:"CS-SECURITY", name:"Security Suite Pro", category:"suite", label:"Suite de segurança",
    price:79.90, recurring:true, badge:"Por usuário / mês", priceBasis:"Valor demonstrativo por usuário; escopo e licenças dependem do ambiente.",
    description:"Camada de segurança para endpoints, controle de acesso e monitoramento.",
    image:"https://images.unsplash.com/photo-1563013544-824ae1b704d3?auto=format&fit=crop&w=1200&q=85",
    fallback:"assets/images/suite.svg", specs:["Endpoints","Acesso","Monitoramento","Relatórios"]
  }
];

const CS_KEYS = Object.freeze({cart:"cloudstart_cart_v7",theme:"cloudstart_theme_v7",wishlist:"cloudstart_wishlist_v7",compare:"cloudstart_compare_v7"});

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

function csCompare(){const data=csRead(CS_KEYS.compare,[]);return Array.isArray(data)?data:[]}
function csSetCompare(ids){localStorage.setItem(CS_KEYS.compare,JSON.stringify([...new Set(ids)].filter(id=>csProduct(id)).slice(0,3)));}
