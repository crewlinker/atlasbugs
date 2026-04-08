env "local" {
  src = "file://schema"
  url = getenv("DATABASE_URL")
  dev = getenv("DEV_URL")
}
