/**
 * CloudStart Frontend
 * -------------------------------------------------------
 * Frontend-only prototype.
 * - Prices are illustrative.
 * - Checkout is intentionally mocked.
 * - The backend must recalculate prices and validate all IDs.
 */

const CONFIG = Object.freeze({
  api: {
    orderEndpoint: "/api/orders",
    quoteEndpoint: "/api/quotes"
  },
  currency: "BRL",
  companySizes: {
    small: { label: "Pequeno porte", discount: 0.05, recommendation: "Pacote Essencial — foco em custo-benefício e operação enxuta." },
    medium: { label: "Médio porte", discount: 0.08, recommendation: "Pacote Profissional — redundância, segurança e crescimento planejado." },
    large: { label: "Grande porte", discount: 0.12, recommendation: "Pacote Enterprise — alta disponibilidade, escala e governança." }
  },
  calculatorPrices: {
    server: 18990,
    switch: 8490,
    firewall: 4890,
    license: 49.90
  }
});

const PRODUCTS = Object.freeze([
  {
    id: "server-r260",
    name: "Dell PowerEdge R260",
    category: "server",
    categoryLabel: "Servidor",
    price: 17999,
    description: "Servidor rack 1U compacto para workloads corporativos e aplicações Near-Edge.",
    image: "https://www.tnc.com.vn/uploads/product/sp2026/ext/server-dell-poweredge-r260-xeon-6315p-6x2-5-r260-625-16g1-2t-171336.webp",
    sourceLabel: "Imagem real do produto"
  },
  {
    id: "server-r360",
    name: "Dell PowerEdge R360",
    category: "server",
    categoryLabel: "Servidor",
    price: 21998,
    description: "Servidor rack 1U para pequenas e médias empresas, virtualização e workloads corporativos.",
    image: "https://www.tnc.com.vn/uploads/product/sp2026/ext/server-dell-poweredge-r260-xeon-6315p-6x2-5-r260-625-16g1-2t-171336.webp",
    sourceLabel: "Imagem real / referência de linha"
  },
  {
    id: "server-t360",
    name: "Dell PowerEdge T360",
    category: "server",
    categoryLabel: "Servidor Torre",
    price: 22999,
    description: "Servidor torre para escritórios, filiais, virtualização e ambientes Near-Edge.",
    image: "https://www.tnc.com.vn/uploads/product/sp2026/ext/server-dell-poweredge-r260-xeon-6315p-6x2-5-r260-625-16g1-2t-171336.webp",
    sourceLabel: "Imagem real / referência de linha"
  },
  {
    id: "switch-catalyst",
    name: "Cisco Catalyst 9200",
    category: "hardware",
    categoryLabel: "Switch",
    price: 8490,
    description: "Switch corporativo para redes seguras, escaláveis e gerenciáveis.",
    image: "https://www.cisco.com/c/dam/en/us/products/collateral/switches/catalyst-9200-series-switches/nb-06-cat9200-series-switches-900x600.jpg",
    sourceLabel: "Imagem de fabricante"
  },
  {
    id: "switch-us24",
    name: "Ubiquiti UniFi Switch 24",
    category: "hardware",
    categoryLabel: "Switch",
    price: 2299,
    description: "Switch Layer 2 com 24 portas Gigabit e 2 portas SFP.",
    image: "https://cdn.ecomm.ui.com/products/fc8d2e53-536f-4de4-834c-dd945260404c/21e3eb26-150f-4c1b-9c0d-ae6cb765a377.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "switch-us24-poe",
    name: "Ubiquiti UniFi Switch 24 PoE",
    category: "hardware",
    categoryLabel: "Switch PoE",
    price: 3899,
    description: "Switch de 24 portas com PoE para access points, câmeras e dispositivos de rede.",
    image: "https://cdn.ecomm.ui.com/products/467359c4-e5c3-487b-ae00-f6b7de29c6fc/bccd785f-176e-4827-91d4-78bbd4b88bd9.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "firewall-60f",
    name: "FortiGate 60F",
    category: "hardware",
    categoryLabel: "Firewall",
    price: 13365,
    description: "Firewall NGFW compacto com SD-WAN, VPN e proteção de rede.",
    image: "https://americk.de/media/68/f9/34/1721751455/Fortinet.svg",
    sourceLabel: "Imagem do produto"
  },
  {
    id: "gateway-udm",
    name: "Ubiquiti Dream Machine Pro",
    category: "hardware",
    categoryLabel: "Gateway",
    price: 3199,
    description: "Gateway UniFi 10G para redes corporativas, segurança e gerenciamento centralizado.",
    image: "https://cdn.ecomm.ui.com/products/9df27ed4-c4ae-471a-8982-f5b0650da76a/7997cc11-b8c5-48e0-8b7e-bed4ded30898.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "gateway-ultra",
    name: "Ubiquiti Cloud Gateway Ultra",
    category: "cloud",
    categoryLabel: "Cloud Gateway",
    price: 1299,
    description: "Gateway compacto para gerenciamento UniFi e roteamento seguro.",
    image: "https://cdn.ecomm.ui.com/products/8d2d9e4b-89f3-49a1-9c17-5d774c0067b4/2e179331-f85a-4bc9-bf3e-d00192522732.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "u6-plus",
    name: "Ubiquiti UniFi U6+",
    category: "hardware",
    categoryLabel: "Wi-Fi 6",
    price: 1099,
    description: "Access point Wi-Fi 6 para pequenas e médias empresas.",
    image: "https://cdn.ecomm.ui.com/products/6d5c6141-e2e9-416a-b789-53e59416bb1a/fe055e16-62dc-408f-844e-a76053e63f0d.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "u7-pro",
    name: "Ubiquiti UniFi U7 Pro",
    category: "hardware",
    categoryLabel: "Wi-Fi 7",
    price: 1599,
    description: "Access point Wi-Fi 7 com 6 GHz para ambientes corporativos de alta demanda.",
    image: "https://cdn.ecomm.ui.com/products/fa8dd4e4-36c8-4c79-a928-22c7bff2ce29/80c7b3d6-8db3-4978-9c17-fef6c8c7f4a8.png",
    sourceLabel: "Imagem real do fabricante"
  },
  {
    id: "business-suite",
    name: "CloudStart Business Suite",
    category: "suite",
    categoryLabel: "Suite",
    price: 49.90,
    recurring: true,
    description: "Suite de serviços para operação, produtividade e gestão de infraestrutura.",
    image: "https://images.unsplash.com/photo-1556761175-b413da4baf72?auto=format&fit=crop&w=900&q=80",
    sourceLabel: "Imagem ilustrativa"
  },
  {
    id: "security-suite",
    name: "Security Suite Pro",
    category: "suite",
    categoryLabel: "Suite",
    price: 79.90,
    recurring: true,
    description: "Camada de segurança para endpoints, acesso e monitoramento.",
    image: "https://images.unsplash.com/photo-1563013544-824ae1b704d3?auto=format&fit=crop&w=900&q=80",
    sourceLabel: "Imagem ilustrativa"
  },
  {
    id: "cloud-pro",
    name: "CloudStart Cloud Pro",
    category: "cloud",
    categoryLabel: "Cloud",
    price: 399,
    recurring: true,
    description: "Ambiente cloud para aplicações com espaço para escala.",
    image: "https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=900&q=80",
    sourceLabel: "Imagem ilustrativa"
  },
  {
    id: "backup-1tb",
    name: "Cloud Backup 1 TB",
    category: "cloud",
    categoryLabel: "Backup",
    price: 89,
    recurring: true,
    description: "Backup em nuvem para dados críticos e recuperação operacional.",
    image: "https://images.unsplash.com/photo-1544197150-b99a580bb7a8?auto=format&fit=crop&w=900&q=80",
    sourceLabel: "Imagem ilustrativa"
  }
]);

const state = {
  companySize: "small",
  category: "all",
  search: "",
  cart: loadCart()
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function formatBRL(value) {
  return new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: CONFIG.currency
  }).format(value);
}

function loadCart() {
  try {
    const saved = JSON.parse(localStorage.getItem("cloudstart_cart") || "[]");
    return Array.isArray(saved) ? saved : [];
  } catch {
    return [];
  }
}

function saveCart() {
  localStorage.setItem("cloudstart_cart", JSON.stringify(state.cart));
}

function getProduct(productId) {
  return PRODUCTS.find((product) => product.id === productId);
}

function addToCart(productId, quantity = 1) {
  const product = getProduct(productId);
  if (!product) return;

  const existing = state.cart.find((item) => item.productId === productId);
  if (existing) existing.quantity += quantity;
  else state.cart.push({ productId, quantity });

  saveCart();
  renderCart();
  updateCartCount();
  showToast(`${product.name} adicionado ao carrinho.`);
}

function updateCartItem(productId, quantity) {
  const item = state.cart.find((entry) => entry.productId === productId);
  if (!item) return;
  item.quantity = Math.max(0, quantity);

  if (item.quantity === 0) {
    state.cart = state.cart.filter((entry) => entry.productId !== productId);
  }

  saveCart();
  renderCart();
  updateCartCount();
  renderCheckoutSummary();
}

function cartTotal() {
  return state.cart.reduce((total, item) => {
    const product = getProduct(item.productId);
    return total + (product ? product.price * item.quantity : 0);
  }, 0);
}

function updateCartCount() {
  $("#cartCount").textContent = state.cart.reduce((total, item) => total + item.quantity, 0);
}

function filteredProducts() {
  return PRODUCTS.filter((product) => {
    const categoryMatch = state.category === "all" || product.category === state.category;
    const searchMatch = `${product.name} ${product.description} ${product.categoryLabel}`
      .toLowerCase()
      .includes(state.search.toLowerCase());
    return categoryMatch && searchMatch;
  });
}

function renderProducts() {
  const grid = $("#productGrid");
  const products = filteredProducts();

  if (!products.length) {
    grid.innerHTML = `<div class="recommendation">Nenhum produto encontrado para os filtros atuais.</div>`;
    return;
  }

  grid.innerHTML = products.map((product) => `
    <article class="product-card">
      <div class="product-image">
        <img src="${product.image}" alt="${product.name}" loading="lazy"
          onerror="this.style.display='none'; this.parentElement.style.background='linear-gradient(135deg,#171721,#30205f)'">
        <span class="image-label">${product.sourceLabel || "Imagem do produto"}</span>
      </div>
      <div class="product-body">
        <span class="product-category">${product.categoryLabel}</span>
        <h3>${product.name}</h3>
        <p>${product.description}</p>
        <div class="product-footer">
          <div class="price">
            <strong>${formatBRL(product.price)}</strong>
            <small>${product.recurring ? "por mês" : "valor fictício"}</small>
          </div>
          <button class="add-btn" data-add="${product.id}">Adicionar</button>
        </div>
      </div>
    </article>
  `).join("");

  $$("[data-add]").forEach((button) => {
    button.addEventListener("click", () => addToCart(button.dataset.add));
  });
}

function renderRecommendation() {
  const config = CONFIG.companySizes[state.companySize];
  $("#recommendation").innerHTML =
    `<strong>${config.label}:</strong> ${config.recommendation} Desconto demonstrativo de ${(config.discount * 100).toFixed(0)}% na calculadora.`;
}

function calculateEstimate() {
  const prices = CONFIG.calculatorPrices;
  const servers = Number($("#calcServers").value) || 0;
  const switches = Number($("#calcSwitches").value) || 0;
  const firewalls = Number($("#calcFirewalls").value) || 0;
  const users = Number($("#calcUsers").value) || 0;
  const cloud = Number($("#calcCloud").value) || 0;

  const subtotal =
    servers * prices.server +
    switches * prices.switch +
    firewalls * prices.firewall +
    users * prices.license;

  const discount = subtotal * CONFIG.companySizes[state.companySize].discount;
  const equipmentTotal = subtotal - discount;

  $("#estimateSubtotal").textContent = formatBRL(subtotal);
  $("#estimateDiscount").textContent = `- ${formatBRL(discount)}`;
  $("#estimateCloud").textContent = formatBRL(cloud);
  $("#estimateTotal").textContent = formatBRL(equipmentTotal + cloud);

  return { servers, switches, firewalls, users, cloud, subtotal, discount, total: equipmentTotal + cloud };
}

function addEstimateToCart() {
  const estimate = calculateEstimate();
  const items = [
    ["server-r550", estimate.servers],
    ["switch-9200", estimate.switches],
    ["firewall-60f", estimate.firewalls],
    ["business-suite", estimate.users]
  ];

  items.forEach(([productId, quantity]) => {
    if (quantity > 0) {
      const existing = state.cart.find((item) => item.productId === productId);
      if (existing) existing.quantity += quantity;
      else state.cart.push({ productId, quantity });
    }
  });

  const cloudMap = { 399: "cloud-pro", 799: "cloud-pro", 1499: "cloud-pro" };
  if (estimate.cloud > 0) {
    const cloudProduct = cloudMap[estimate.cloud];
    const existing = state.cart.find((item) => item.productId === cloudProduct);
    if (existing) existing.quantity += 1;
    else state.cart.push({ productId: cloudProduct, quantity: 1 });
  }

  saveCart();
  renderCart();
  updateCartCount();
  showToast("Estimativa adicionada ao carrinho.");
}

function renderCart() {
  const container = $("#cartItems");

  if (!state.cart.length) {
    container.innerHTML = `<p class="muted">Seu carrinho está vazio.</p>`;
    $("#cartTotal").textContent = formatBRL(0);
    return;
  }

  container.innerHTML = state.cart.map((item) => {
    const product = getProduct(item.productId);
    if (!product) return "";

    return `
      <div class="cart-row">
        <div><strong>${product.name}</strong><small>${formatBRL(product.price)} ${product.recurring ? "/mês" : ""}</small></div>
        <div class="qty">
          <button data-minus="${product.id}">−</button>
          <span>${item.quantity}</span>
          <button data-plus="${product.id}">+</button>
        </div>
        <button class="remove-btn" data-remove="${product.id}">Remover</button>
      </div>
    `;
  }).join("");

  $("#cartTotal").textContent = formatBRL(cartTotal());

  $$("[data-minus]").forEach((button) => button.addEventListener("click", () => {
    const item = state.cart.find((entry) => entry.productId === button.dataset.minus);
    updateCartItem(button.dataset.minus, (item?.quantity || 1) - 1);
  }));

  $$("[data-plus]").forEach((button) => button.addEventListener("click", () => {
    const item = state.cart.find((entry) => entry.productId === button.dataset.plus);
    updateCartItem(button.dataset.plus, (item?.quantity || 0) + 1);
  }));

  $$("[data-remove]").forEach((button) => button.addEventListener("click", () => {
    updateCartItem(button.dataset.remove, 0);
  }));
}

function openModal(id) {
  const modal = $(`#${id}`);
  if (!modal) return;
  modal.hidden = false;
  document.body.classList.add("modal-open");
}

function closeModal(id) {
  const modal = $(`#${id}`);
  if (!modal) return;
  modal.hidden = true;
  document.body.classList.remove("modal-open");
}

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("show"), 2600);
}

function renderCheckoutSummary() {
  const container = $("#checkoutSummaryItems");
  if (!container) return;

  container.innerHTML = state.cart.map((item) => {
    const product = getProduct(item.productId);
    if (!product) return "";
    return `
      <div class="summary-product">
        <img src="${product.image}" alt="" onerror="this.style.display='none'">
        <div>
          <strong>${product.name}</strong>
          <small>${item.quantity} unidade(s) • ${formatBRL(product.price * item.quantity)}</small>
        </div>
      </div>
    `;
  }).join("");

  const total = cartTotal();
  $("#checkoutSubtotal").textContent = formatBRL(total);
  $("#checkoutTotal").textContent = formatBRL(total);
}

function buildOrderPayload(formData) {
  return {
    items: state.cart.map((item) => {
      const product = getProduct(item.productId);
      return {
        productId: item.productId,
        quantity: item.quantity,
        // Informativo no frontend; o backend deve buscar o preço oficial.
        displayedUnitPrice: product?.price ?? 0
      };
    }),
    companySize: state.companySize,
    payment: { method: formData.get("paymentMethod") },
    customer: {
      name: formData.get("name"),
      email: formData.get("email")
    },
    createdAt: new Date().toISOString()
  };
}

async function submitOrder(payload) {
  // Integração futura:
  // const response = await fetch(CONFIG.api.orderEndpoint, {
  //   method: "POST",
  //   headers: { "Content-Type": "application/json" },
  //   body: JSON.stringify(payload)
  // });
  // return response.json();

  console.info("[CloudStart] Pedido pronto para backend:", payload);
  return { demo: true, status: "pending" };
}

function initialize() {
  $("#searchInput").addEventListener("input", (event) => {
    state.search = event.target.value;
    renderProducts();
  });

  $("#categoryFilter").addEventListener("change", (event) => {
    state.category = event.target.value;
    renderProducts();
  });

  $$(".size-option").forEach((button) => {
    button.addEventListener("click", () => {
      $$(".size-option").forEach((item) => item.classList.remove("active"));
      button.classList.add("active");
      state.companySize = button.dataset.size;
      renderRecommendation();
      calculateEstimate();
    });
  });

  ["calcServers", "calcSwitches", "calcFirewalls", "calcUsers", "calcCloud"]
    .forEach((id) => $(`#${id}`).addEventListener("input", calculateEstimate));

  $("#addEstimate").addEventListener("click", addEstimateToCart);
  $("#requestQuote").addEventListener("click", () => openModal("quoteModal"));

  $("#openCart").addEventListener("click", () => {
    renderCart();
    openModal("cartModal");
  });

  $("#checkoutBtn").addEventListener("click", () => {
    if (!state.cart.length) {
      showToast("Adicione produtos antes de continuar.");
      return;
    }
    closeModal("cartModal");
    renderCheckoutSummary();
    openModal("checkoutModal");
  });

  $$("[data-close]").forEach((button) => {
    button.addEventListener("click", () => closeModal(button.dataset.close));
  });

  $$(".modal-backdrop").forEach((backdrop) => {
    backdrop.addEventListener("click", (event) => {
      if (event.target === backdrop) closeModal(backdrop.id);
    });
  });

  $("#checkoutForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const payload = buildOrderPayload(new FormData(event.currentTarget));
    const result = await submitOrder(payload);
    if (result.demo) {
      showToast("Pedido preparado para integração com o backend.");
      closeModal("checkoutModal");
    }
  });

  $("#quoteForm").addEventListener("submit", (event) => {
    event.preventDefault();
    console.info("[CloudStart] Orçamento:", Object.fromEntries(new FormData(event.currentTarget)));
    closeModal("quoteModal");
    showToast("Solicitação de orçamento preparada.");
    event.currentTarget.reset();
  });

  $$('input[name="paymentMethod"]').forEach((radio) => {
    radio.addEventListener("change", () => {
      $$(".payment-option").forEach((option) => option.classList.remove("selected"));
      radio.closest(".payment-option").classList.add("selected");
      const isCard = radio.value === "credit_card" || radio.value === "debit_card";
      $("#cardFields").hidden = !isCard;
      $("#pixInfo").hidden = radio.value !== "pix";

      const installments = $("#installments");
      const installmentField = installments?.closest(".field");
      if (installmentField) {
        installmentField.hidden = radio.value !== "credit_card";
      }

      const cardTitle = document.querySelector("#cardFields .security-note");
      if (cardTitle) {
        cardTitle.textContent = radio.value === "debit_card"
          ? "🔒 No produto real, os dados do cartão de débito devem ser tratados por um gateway de pagamento."
          : "🔒 Em produção, os dados do cartão devem ser tokenizados por um gateway de pagamento. Não armazene CVV.";
      }
    });
  });

  $("[data-cloud-modal]").addEventListener("click", () => openModal("cloudModal"));

  $$(".plan-choice").forEach((button) => {
    button.addEventListener("click", () => {
      $("#calcCloud").value = button.dataset.cloudPrice;
      calculateEstimate();
      closeModal("cloudModal");
      document.querySelector("#calculadora").scrollIntoView({ behavior: "smooth" });
      showToast("Plano Cloud selecionado.");
    });
  });

  $("#supportBtn").addEventListener("click", () => openModal("quoteModal"));
  $("#applyCoupon").addEventListener("click", () => {
    const code = $("#couponInput").value.trim().toUpperCase();
    if (!code) {
      showToast("Digite um cupom.");
      return;
    }
    if (code === "CLOUD10") {
      const discounted = cartTotal() * 0.90;
      $("#checkoutTotal").textContent = formatBRL(discounted);
      showToast("Cupom CLOUD10 aplicado.");
    } else {
      showToast("Cupom demonstrativo não encontrado.");
    }
  });


  $("#menuToggle").addEventListener("click", () => $("#mainNav").classList.toggle("open"));

  $("#themeToggle").addEventListener("click", () => {
    const nextTheme = document.documentElement.dataset.theme === "light" ? "dark" : "light";
    document.documentElement.dataset.theme = nextTheme;
    localStorage.setItem("cloudstart_theme", nextTheme);
    $("#themeToggle").textContent = nextTheme === "light" ? "☀" : "☾";
  });

  const savedTheme = localStorage.getItem("cloudstart_theme");
  if (savedTheme === "light") {
    document.documentElement.dataset.theme = "light";
    $("#themeToggle").textContent = "☀";
  }

  renderProducts();
  renderRecommendation();
  calculateEstimate();
  renderCart();
  updateCartCount();
  renderCheckoutSummary();
}

document.addEventListener("DOMContentLoaded", initialize);
