FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build

ARG SERVICE
WORKDIR /src
RUN apk add --no-cache protobuf
COPY go.mod go.sum ./
RUN go mod download
COPY proto ./proto
COPY cmd ./cmd
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.8 \
  && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1 \
  && mkdir -p genproto \
  && protoc -I proto \
    --go_out=genproto --go_opt=paths=source_relative \
    --go-grpc_out=genproto --go-grpc_opt=paths=source_relative \
    proto/demo.proto
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/bridge ./cmd/bridge

FROM gcr.io/distroless/static-debian12:nonroot
ARG SERVICE
COPY --from=build /out/bridge /bridge
ENV SERVICE=${SERVICE}
EXPOSE 5000 7000 9555 50051 9091
ENTRYPOINT ["/bridge"]
