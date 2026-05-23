ARG BUILD_FROM
FROM ${BUILD_FROM}

# git   — fetch from GitHub
# curl  — Supervisor API calls (check-config, reload)
# jq    — parse JSON API responses
RUN apk add --no-cache bash git curl jq

COPY run.sh /
RUN chmod +x /run.sh

CMD ["/run.sh"]
