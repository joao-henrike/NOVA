data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.global_tags, {
    Name = local.name
  })

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.availability_zone_count
      error_message = "The selected AWS region does not have enough available Availability Zones."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name = "${local.name}-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = local.subnets_by_az

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.public_cidr
  map_public_ip_on_launch = true

  tags = merge(local.global_tags, {
    Name = "${local.name}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private_app" {
  for_each = local.subnets_by_az

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.private_app_cidr
  map_public_ip_on_launch = false

  tags = merge(local.global_tags, {
    Name = "${local.name}-private-app-${each.key}"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_db" {
  for_each = local.subnets_by_az

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.private_db_cidr
  map_public_ip_on_launch = false

  tags = merge(local.global_tags, {
    Name = "${local.name}-private-db-${each.key}"
    Tier = "private-db"
  })
}

resource "aws_eip" "nat" {
  for_each = toset(local.azs)

  domain = "vpc"

  tags = merge(local.global_tags, {
    Name = "${local.name}-nat-eip-${each.key}"
  })
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  depends_on = [aws_internet_gateway.this]

  tags = merge(local.global_tags, {
    Name = "${local.name}-nat-${each.key}"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.global_tags, {
    Name = "${local.name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  route_table_id = aws_route_table.public.id
  subnet_id      = each.value.id
}

resource "aws_route_table" "private_app" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[each.key].id
  }

  tags = merge(local.global_tags, {
    Name = "${local.name}-private-app-${each.key}-rt"
  })
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  route_table_id = aws_route_table.private_app[each.key].id
  subnet_id      = each.value.id
}

resource "aws_route_table" "private_db" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.this.id

  tags = merge(local.global_tags, {
    Name = "${local.name}-private-db-${each.key}-rt"
  })
}

resource "aws_route_table_association" "private_db" {
  for_each = aws_subnet.private_db

  route_table_id = aws_route_table.private_db[each.key].id
  subnet_id      = each.value.id
}


resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  ingress = []
  egress  = []

  tags = merge(local.global_tags, {
    Name = "${local.name}-default-sg"
  })
}
