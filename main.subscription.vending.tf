# ========================================
# Terraformのサブスクリプションリソースの実装
# モジュールを使わず、azurerm_subscriptionリソースを使用
# ALZモジュールとの互換性維持のため
# ========================================

locals {
  # subscriptions/ディレクトリからYAMLファイルを読み込む
  subscription_files = fileset("${path.module}/subscriptions", "*.yaml")

  # YAMLをパースして設定を作成（README.mdは説明用のファイルとして除外）
  subscriptions = {
    for file in local.subscription_files :
    trimsuffix(file, ".yaml") => yamldecode(file("${path.module}/subscriptions/${file}"))
    if file != "README.md"
  }
}

# 手順3: 管理グループIDの取得
data "azurerm_management_group" "subscription_target" {
  for_each = local.subscriptions

  name = each.value.management_group_id
}

# データソースでBilling Scopeを取得
data "azurerm_billing_mca_account_scope" "this" {
  count = var.billing_account_name != null && var.billing_profile_name != null && var.invoice_section_name != null ? 1 : 0

  billing_account_name = var.billing_account_name
  billing_profile_name = var.billing_profile_name
  invoice_section_name = var.invoice_section_name
}

# 手順4: サブスクリプションの作成
resource "azurerm_subscription" "this" {
  for_each = local.subscriptions

  subscription_name = each.value.display_name
  alias             = each.key
  billing_scope_id  = data.azurerm_billing_mca_account_scope.this[0].id
  workload          = lookup(each.value, "workload_type", "Production")

  tags = lookup(each.value, "tags", {})

  # サブスクリプション作成は時間がかかるため、タイムアウトを延長
  timeouts {
    create = "60m"
    read   = "5m"
    update = "60m"
    delete = "60m"
  }

  # ライフサイクル: サブスクリプションは削除せず、管理グループのみ変更可能
  lifecycle {
    prevent_destroy = true
  }
}

# 手順5: 管理グループへの関連付け
resource "azurerm_management_group_subscription_association" "this" {
  for_each = local.subscriptions

  management_group_id = data.azurerm_management_group.subscription_target[each.key].id
  subscription_id     = "/subscriptions/${azurerm_subscription.this[each.key].subscription_id}"

  depends_on = [azurerm_subscription.this]
}

# 手順6: リソースグループの作成
locals {
  # 全サブスクリプションのリソースグループをフラット化
  subscription_resource_groups = merge([
    for sub_key, sub in local.subscriptions : {
      for rg_key, rg in lookup(sub, "resource_groups", {}) :
      "${sub_key}-${rg_key}" => merge(rg, {
        subscription_id = azurerm_subscription.this[sub_key].subscription_id
        location        = lookup(rg, "location", lookup(sub, "location", "japaneast"))
        tags            = lookup(sub, "tags", {})
      })
    }
  ]...)
}

resource "azurerm_resource_group" "this" {
  for_each = local.subscription_resource_groups

  name     = each.value.name
  location = each.value.location
  tags     = each.value.tags

  # プロバイダーエイリアスは使用せず、subscription_idで制御
  lifecycle {
    ignore_changes = [tags]
  }

  depends_on = [azurerm_subscription.this]
}

# 手順7: VNetの作成
locals {
  # VNetが定義されているサブスクリプションを抽出
  vnets = {
    for sub_key, sub in local.subscriptions :
    sub_key => merge(sub.virtual_network, {
      subscription_id = azurerm_subscription.this[sub_key].subscription_id
      location        = lookup(sub.virtual_network, "location", lookup(sub, "location", "japaneast"))
      tags            = lookup(sub, "tags", {})
    })
    if lookup(sub, "virtual_network", null) != null
  }
}

resource "azurerm_virtual_network" "this" {
  for_each = local.vnets

  name                = each.value.name
  location            = each.value.location
  resource_group_name = each.value.resource_group_name
  address_space       = each.value.address_space
  tags                = each.value.tags

  depends_on = [
    azurerm_resource_group.this,
    azurerm_subscription.this
  ]
}

# 手順8: サブネットの作成
locals {
  # 全VNetのサブネットをフラット化
  subnets = merge([
    for sub_key, vnet in local.vnets : {
      for subnet in lookup(vnet, "subnets", []) :
      "${sub_key}-${subnet.name}" => {
        name                = subnet.name
        vnet_name           = vnet.name
        resource_group_name = vnet.resource_group_name
        address_prefix      = subnet.address_prefix
        subscription_id     = vnet.subscription_id
      }
    }
  ]...)
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = each.value.name
  resource_group_name  = each.value.resource_group_name
  virtual_network_name = each.value.vnet_name
  address_prefixes     = [each.value.address_prefix]

  depends_on = [azurerm_virtual_network.this]
}

# 手順9: Hub VNetへのピアリング
locals {
  # Hub接続が必要なVNetを抽出
  # Hub VNet情報は既存のhub_and_spoke_vnetモジュールから自動取得
  hub_vnet_id = try(
    values(module.hub_and_spoke_vnet[0].virtual_network_resource_ids)[0],
    var.hub_virtual_network_id
  )
  hub_vnet_name = try(
    values(module.hub_and_spoke_vnet[0].virtual_network_resource_names)[0],
    var.hub_virtual_network_name
  )
  hub_vnet_resource_group = try(
    split("/", local.hub_vnet_id)[4],
    var.hub_virtual_network_resource_group_name
  )

  vnet_peerings = {
    for sub_key, vnet in local.vnets :
    sub_key => vnet
    if lookup(vnet, "hub_peering_enabled", false) && local.hub_vnet_id != null
  }
}

# Spoke → Hub のピアリング
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = local.vnet_peerings

  name                      = "${each.value.name}-to-hub"
  resource_group_name       = each.value.resource_group_name
  virtual_network_name      = each.value.name
  remote_virtual_network_id = local.hub_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = lookup(each.value, "use_hub_gateway", false)

  depends_on = [azurerm_virtual_network.this]
}

# Hub → Spoke のピアリング
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = local.vnet_peerings

  name                      = "hub-to-${each.value.name}"
  resource_group_name       = local.hub_vnet_resource_group
  virtual_network_name      = local.hub_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.this[each.key].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = lookup(each.value, "use_hub_gateway", false)
  use_remote_gateways          = false

  depends_on = [azurerm_virtual_network.this]
}