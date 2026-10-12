FROM golang:1.27.2-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /relay .
FROM build AS test
RUN apk add --no-cache gcc musl-dev
CMD ["go", "test", "-race", "-count=1", "./..."]
FROM build AS audit
RUN go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /relay /relay
EXPOSE 8080
ENTRYPOINT ["/relay"]
