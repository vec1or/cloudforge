resource "kubernetes_namespace_v1" "cloudforge_managed" {
  metadata {
    name = "cloudforge-managed"

    labels = {
      "app.kubernetes.io/part-of"    = "cloudforge"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}