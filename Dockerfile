# Imagem enxuta para servir os arquivos estáticos do frontend.
FROM nginx:1.27-alpine

# Remove a configuração default para evitar comportamento inesperado.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html/

EXPOSE 80

# O Nginx permanece em foreground para o ECS acompanhar o processo.
CMD ["nginx", "-g", "daemon off;"]
