# 既存のサブスクリプションをTerraform管理下に取り込む
import {
  to = azurerm_subscription.this["demo-app-dev"]
  id = "/providers/Microsoft.Subscription/aliases/demo-app-dev"
}
