# =============================================================================
# FlashTicket - Réseau : VPC, 6 sous-réseaux sur 2 zones, 3 groupes de sécurité
#
#   Internet ──443──> [public] ──8443/22──> [applicatif] ──5432──> [données]
#
# Chaque niveau n'accepte que le niveau précédent, sur son seul port.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "flashticket"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-3" # Paris
}

variable "vpc_cidr" {
  description = "Plage d'adresses du VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "admin_cidr" {
  description = "Réseau autorisé à se connecter en SSH au segment public (ex. ton IP en /32)"
  type        = string
  default     = "78.241.183.206/32"

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr doit être un CIDR valide et ne pas être 0.0.0.0/0."
  }
}

variable "app_port" {
  description = "Port du service applicatif (ticketpdf)"
  type        = number
  default     = 8443
}

variable "data_port" {
  description = "Port de la base de données (5432 = PostgreSQL)"
  type        = number
  default     = 5432
}

# -----------------------------------------------------------------------------
# Zones et plan d'adressage
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Décalage du troisième octet pour chaque niveau :
  #   public  : 10.0.1.0/24,  10.0.2.0/24
  #   app     : 10.0.11.0/24, 10.0.12.0/24
  #   data    : 10.0.21.0/24, 10.0.22.0/24
  tiers = {
    public = 0
    app    = 10
    data   = 20
  }

  subnets = merge([
    for tier, offset in local.tiers : {
      for i, az in local.azs : "${tier}-${i + 1}" => {
        tier = tier
        az   = az
        cidr = cidrsubnet(var.vpc_cidr, 8, offset + i + 1)
      }
    }
  ]...)
}

# -----------------------------------------------------------------------------
# VPC et sous-réseaux
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "flashticket-vpc"
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # Aucune IP publique automatique, même dans le segment public :
  # on attribuera une IP élastique explicitement si nécessaire.
  map_public_ip_on_launch = false

  tags = {
    Name = "flashticket-${each.key}"
    Tier = each.value.tier
  }
}

# -----------------------------------------------------------------------------
# Accès Internet : uniquement pour les sous-réseaux publics
# (les sous-réseaux app et données restent sur la table de routage
#  principale du VPC, sans route vers Internet)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "flashticket-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "flashticket-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = { for k, s in local.subnets : k => s if s.tier == "public" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Groupe de sécurité par défaut du VPC : verrouillé (aucune règle)
# -----------------------------------------------------------------------------

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "flashticket-default-locked"
  }
}

# -----------------------------------------------------------------------------
# Groupes de sécurité
# (règles déclarées séparément pour éviter les dépendances circulaires)
#
# Les descriptions restent en ASCII, sans accent ni apostrophe : AWS les refuse
# à l'apply, alors que terraform validate et terraform plan ne le signalent pas.
# -----------------------------------------------------------------------------

resource "aws_security_group" "public" {
  name        = "flashticket-public"
  description = "Segment public : HTTPS depuis Internet, SSH depuis le reseau admin"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "flashticket-sg-public"
  }
}

resource "aws_security_group" "app" {
  name        = "flashticket-app"
  description = "Segment applicatif : accepte uniquement le segment public"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "flashticket-sg-app"
  }
}

resource "aws_security_group" "data" {
  name        = "flashticket-data"
  description = "Segment donnees : accepte uniquement le segment applicatif, port de la base"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "flashticket-sg-data"
  }
}

# --- Public : entrées ---------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "public_https" {
  security_group_id = aws_security_group.public.id
  description       = "HTTPS depuis Internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "public_ssh" {
  security_group_id = aws_security_group.public.id
  description       = "SSH depuis le reseau admin uniquement"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

# --- Public : sorties ---------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "public_to_app" {
  security_group_id            = aws_security_group.public.id
  description                  = "Vers le service applicatif"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "public_ssh_to_app" {
  security_group_id            = aws_security_group.public.id
  description                  = "Rebond SSH vers le segment applicatif"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "public_https_out" {
  security_group_id = aws_security_group.public.id
  description       = "Mises a jour (HTTPS sortant)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Applicatif : entrées (uniquement depuis le public) -----------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_public" {
  security_group_id            = aws_security_group.app.id
  description                  = "ticketpdf depuis le segment public"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.public.id
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_public" {
  security_group_id            = aws_security_group.app.id
  description                  = "SSH depuis le segment public (bastion)"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.public.id
}

# --- Applicatif : sorties -----------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "app_to_data" {
  security_group_id            = aws_security_group.app.id
  description                  = "Vers la base de donnees"
  ip_protocol                  = "tcp"
  from_port                    = var.data_port
  to_port                      = var.data_port
  referenced_security_group_id = aws_security_group.data.id
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "Mises a jour (HTTPS sortant, via NAT si ajoute)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Données : entrées (uniquement depuis l'applicatif, sur son port) ---------

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  security_group_id            = aws_security_group.data.id
  description                  = "Base de donnees depuis le segment applicatif uniquement"
  ip_protocol                  = "tcp"
  from_port                    = var.data_port
  to_port                      = var.data_port
  referenced_security_group_id = aws_security_group.app.id
}

# Données : aucune règle de sortie. Les groupes de sécurité étant "stateful",
# les réponses aux connexions entrantes restent autorisées.

# -----------------------------------------------------------------------------
# Sorties
# -----------------------------------------------------------------------------

output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  description = "Identifiants des sous-réseaux, par niveau et par zone"
  value       = { for k, s in aws_subnet.this : k => s.id }
}

output "subnet_cidrs" {
  value = { for k, s in aws_subnet.this : k => "${s.cidr_block} (${s.availability_zone})" }
}

output "security_group_ids" {
  value = {
    public = aws_security_group.public.id
    app    = aws_security_group.app.id
    data   = aws_security_group.data.id
  }
}
