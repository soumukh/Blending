FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 go build -o /out/function ./cmd/function

FROM ghcr.io/openfaas/of-watchdog:0.10.9 AS watchdog

FROM alpine:3.21
ARG SERVICE
RUN addgroup -S app && adduser -S -g app app
COPY --from=watchdog /fwatchdog /usr/bin/fwatchdog
COPY --from=build /out/function /home/app/function
RUN chmod +x /usr/bin/fwatchdog /home/app/function
USER app
WORKDIR /home/app
ENV SERVICE=${SERVICE}
ENV mode=http
ENV upstream_url=http://127.0.0.1:8082
ENV fprocess=/home/app/function
ENV read_timeout=60s
ENV write_timeout=60s
ENV exec_timeout=60s
HEALTHCHECK --interval=30s --timeout=3s CMD ["/home/app/function", "-healthcheck"]
ENTRYPOINT ["fwatchdog"]
