FROM nginx:1.28-alpine
COPY host/nginx.conf /etc/nginx/conf.d/default.conf
COPY docs/ /usr/share/nginx/html/
EXPOSE 8080
