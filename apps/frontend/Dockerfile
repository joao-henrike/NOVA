FROM nginx:1.31-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/

# Fail the build if the landing page is absent. Nginx workers must be able to
# read static files even when the host checkout has a restrictive umask.
RUN test -s /usr/share/nginx/html/index.html \
    && find /usr/share/nginx/html -type d -exec chmod 755 {} + \
    && find /usr/share/nginx/html -type f -exec chmod 644 {} + \
    && nginx -t

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q -O - http://127.0.0.1/health >/dev/null || exit 1
