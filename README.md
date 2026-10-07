# CloudStart Frontend V2

Frontend puro em HTML + CSS + JavaScript.

## Incluído

- Catálogo de suites, servidores, hardware e cloud.
- Fotos ilustrativas dos produtos.
- Filtro e busca.
- Carrinho com localStorage.
- Seleção de porte: pequeno, médio e grande.
- Calculadora de infraestrutura.
- Descontos demonstrativos por porte.
- Planos Cloud.
- Checkout demonstrativo com PIX, cartão e boleto.
- Modal de orçamento.
- Dark/light mode.
- Responsividade mobile.
- Estrutura preparada para integração com backend.
- Sem pagamento real.

## Boas práticas

Os preços exibidos no navegador são apenas informativos. Em uma implementação real, o backend deve:

1. Receber somente IDs e quantidades.
2. Buscar os preços oficiais no banco.
3. Recalcular subtotal, descontos e total.
4. Validar estoque e regras comerciais.
5. Criar a cobrança usando um gateway de pagamento.
6. Nunca armazenar CVV ou dados sensíveis de cartão.
7. Usar autenticação, autorização, HTTPS e idempotência.
8. Atualizar o pedido por webhook assinado do gateway.

## Imagens

As imagens são externas e ilustrativas. Em produção, substitua por imagens próprias/CDN da empresa.

## Execução

Abra `index.html` no navegador ou utilize um servidor estático, por exemplo:

```bash
python -m http.server 8080
```

Depois acesse `http://localhost:8080`.

## Imagens de produtos

A versão atual usa imagens reais de produtos/linhas encontradas em páginas de fabricantes ou revendedores, incluindo Ubiquiti, Dell e Fortinet. Alguns itens de software/suites continuam usando imagens ilustrativas.

Para produção, o ideal é armazenar as imagens autorizadas em uma CDN própria da CloudStart e manter os respectivos direitos/licenças de uso.
