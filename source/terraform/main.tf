
provider "azurerm" {
  features {}
}

# create resource groups 
resource "azurerm_resource_group" "demo" {
  name     = "demo-dns-ew"
  location = "West Europe"
}


# creeate private DNS zone
resource "azurerm_private_dns_zone" "demo" {
  name                = "private.com"
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_private_dns_a_record" "demo" {
  name                = "hello"
  zone_name           = azurerm_private_dns_zone.demo.name
  resource_group_name = azurerm_resource_group.demo.name
  ttl                 = 30
  records             = ["10.10.10.10"]
}
##############
# 1. hub vnet
##############
# create vnet
resource "azurerm_virtual_network" "ew_hub" {
  name                = "vnet-ew-hub"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  address_space       = ["10.1.0.0/16"]
}

# create subnet for private dns resolver outbound
# Endpoint creation with subnet of address space overlapping 10.0.0.0/24 through 10.0.16.0/24 might fail.
resource "azurerm_subnet" "ew_hub_dns_outbound" {
  name                 = "outbounddns"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.ew_hub.name
  address_prefixes     = ["10.1.0.0/28"]

  delegation {
    name = "Microsoft.Network.dnsResolvers"
    service_delegation {
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      name    = "Microsoft.Network/dnsResolvers"
    }
  }
}
resource "azurerm_subnet" "ew_hub_dns_inbound" {
  name                 = "inbounddns"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.ew_hub.name
  address_prefixes     = ["10.1.0.16/28"]

  delegation {
    name = "Microsoft.Network.dnsResolvers"
    service_delegation {
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      name    = "Microsoft.Network/dnsResolvers"
    }
  }
}
# link dns zone to vnet
resource "azurerm_private_dns_zone_virtual_network_link" "ew" {
  name                  = "ew-hub"
  resource_group_name   = azurerm_resource_group.demo.name
  private_dns_zone_name = azurerm_private_dns_zone.demo.name
  virtual_network_id    = azurerm_virtual_network.ew_hub.id
}

##############
# 2. DNS resolver
##############
# create private resolver
resource "azurerm_private_dns_resolver" "ew" {
  name                = "resolv-ew"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  virtual_network_id  = azurerm_virtual_network.ew_hub.id
}
# create outbound enpoint
resource "azurerm_private_dns_resolver_outbound_endpoint" "ew" {
  name                    = "ew-outbound-endpoint"
  private_dns_resolver_id = azurerm_private_dns_resolver.ew.id
  location                = azurerm_private_dns_resolver.ew.location
  subnet_id               = azurerm_subnet.ew_hub_dns_outbound.id
  tags = {
    env = "dns-demo"
  }
}

# create inbound enpoint
resource "azurerm_private_dns_resolver_inbound_endpoint" "ew" {
  name                    = "ew-inbound-endpoint"
  private_dns_resolver_id = azurerm_private_dns_resolver.ew.id
  location                = azurerm_private_dns_resolver.ew.location
  ip_configurations {
    private_ip_allocation_method = "Dynamic"
    subnet_id                    = azurerm_subnet.ew_hub_dns_inbound.id
  }
  tags = {
    env = "dns-demo"
  }
}

# Create dns forwarding ruleset, please note
# A single ruleset can be associated with multiple outbound endpoints.
# A ruleset can have up to 1000 DNS forwarding rules.
# A ruleset can be linked to up to 500 virtual networks in the same region
# https://learn.microsoft.com/en-us/azure/dns/private-resolver-endpoints-rulesets#dns-forwarding-rulesets
resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "ew" {
  name                                       = "ew-ruleset"
  resource_group_name                        = azurerm_resource_group.demo.name
  location                                   = azurerm_resource_group.demo.location
  private_dns_resolver_outbound_endpoint_ids = [azurerm_private_dns_resolver_outbound_endpoint.ew.id]
  tags = {
    env = "dns-demo"
  }
}
# add forward rule for private.com to ruleset
resource "azurerm_private_dns_resolver_forwarding_rule" "private_com" {
  name                      = "private-com"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.ew.id
  domain_name               = "private.com."
  enabled                   = true
  target_dns_servers {
    # the inbound endpoint ip
    ip_address = azurerm_private_dns_resolver_inbound_endpoint.ew.ip_configurations[0].private_ip_address
    port       = 53
  }
  metadata = {
    env = "dns-demo"
  }
}

##############
# 3. spoke vnet
##############
# create spoke vnet
resource "azurerm_virtual_network" "ew_spoke" {
  name                = "vnet-eu-wests-spoke"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  address_space       = ["10.2.0.0/16"]
}

resource "azurerm_subnet" "ew_spoke_vm" {
  name                 = "vm"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.ew_spoke.name
  address_prefixes     = ["10.2.0.0/24"]
}

resource "azurerm_public_ip" "public_ip" {
  name                = "dns-demo-test"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "dns_test" {
  name                = "dns-test-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.ew_spoke_vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.public_ip.id
  }
}

resource "azurerm_virtual_machine" "dns_test" {
  name                  = "test-dns-vm"
  location              = azurerm_resource_group.demo.location
  resource_group_name   = azurerm_resource_group.demo.name
  network_interface_ids = [azurerm_network_interface.dns_test.id]
  vm_size               = "Standard_DS1_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "dns-test"
    admin_username = "testadmin"
    # admin_password = "Password1234!"
  }
  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      path     = "/home/testadmin/.ssh/authorized_keys"
      key_data = file("~/.ssh/id_rsa.pub")
    }
  }
  tags = {
    env = "demo"
  }
}

##############
# 4. link ruleset to vnets(hub & spoke)
##############
# https://learn.microsoft.com/en-us/azure/dns/private-resolver-endpoints-rulesets#ruleset-links
resource "azurerm_private_dns_resolver_virtual_network_link" "ew_hub" {
  name                      = "ew_hub-link"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.ew.id
  virtual_network_id        = azurerm_virtual_network.ew_hub.id
  metadata = {
    env = "demo"
  }
}

resource "azurerm_private_dns_resolver_virtual_network_link" "ew_spoke" {
  name                      = "ew_spoke-link"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.ew.id
  virtual_network_id        = azurerm_virtual_network.ew_spoke.id
  metadata = {
    env = "demo"
  }
}

output "test_cmd" {
  value = "ssh testadmin@${azurerm_public_ip.public_ip.ip_address} dig hello.private.com"
}
