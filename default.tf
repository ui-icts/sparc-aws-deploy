# Set up AWS access keys and default region

provider "aws" {
  access_key = "YOUR_KEY_HERE"
  secret_key = "YOUR_KEY_HERE"
  region     = "us-east-2"
}


variable "dept_mfk" {
  default     = ""
  description = "MFK Used to tag all resources"
}

# Need to define a VPC (virtual private cloud) to network our two
# AWS machines (database and web) together
# Similar to picture here https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Tutorials.WebServerDB.CreateVPC.html
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/images/con-VPC-sec-grp.png
resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
  tags {
    CA001 = "${var.dept_mfk}"
  }
}

# Our webserver will get put into the public subnet so that it
# can take requests from WWW
# and our DB will be put into the private subnet

resource "aws_subnet" "public_subnet" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "10.0.0.0/24"
  
  map_public_ip_on_launch = true

  tags {
    Name = "main_subnet1"
    CA001 = "${var.dept_mfk}"
  }

  depends_on = ["aws_internet_gateway.default"]
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-2c"

  tags {
    Name = "private_subnet_1"
    CA001 = "${var.dept_mfk}"
  }
}

# Per tutorial (https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Tutorials.WebServerDB.CreateVPC.html)
# you have to have two subnets for amazon RDS so we're going to set those up next.
# since our DB is private, we create a second private subnet

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-2a"

  tags {
    Name = "private_subnet_2"
    CA001 = "${var.dept_mfk}"
  }
}

resource "aws_db_subnet_group" "default" {
  name        = "db_subnet_group"
  description = "Group of subnets used for our RDS database"
  subnet_ids  = ["${aws_subnet.private_subnet_1.id}", "${aws_subnet.private_subnet_2.id}"]
  tags {
    CA001 = "${var.dept_mfk}"
  }
}


# Security groups provide instance level security (sort of like a firewall)


resource "aws_security_group" "database" {
  name        = "Database Security Group"
  description = "Allow MySQL traffic from our webserver"
  vpc_id      = "${aws_vpc.default.id}"

  # restrict to MySQL port, but from any host.
  # I think the fact it's on a subnet and I only have 
  # 1 other webserver means it's probably OK right now
  # but TODO: need to figure out if I should be putting the
  # cidr block for my web hosts. The AWS doc page mentions
  # that in the UI you can pick a source that is another security
  # group for the webserver you have already created.
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # do not allow outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "Database security group"
    CA001 = "${var.dept_mfk}"
  } 
}

# Now we're ready to create our DB instance

resource "aws_db_instance" "sparc_db" {
  depends_on                = ["aws_security_group.database"]
  identifier                = "sparcdb-rds"
  allocated_storage         = 10
  storage_type              = "gp2"
  engine                    = "mysql"
  engine_version            = "5.7.19"
  instance_class            = "db.t2.micro"
  name                      = "sparc_rails"
  username                  = "sparc"
  password                  = "rails2010sliar"
  vpc_security_group_ids    = ["${aws_security_group.database.id}"]
  db_subnet_group_name      = "${aws_db_subnet_group.default.id}"
  final_snapshot_identifier = "sparc-database-snapshot"
  skip_final_snapshot       = true
  tags {
    CA001 = "${var.dept_mfk}"
  }
}

###########################
# Web server
###########################

# Create an internet gateway to give our subnet access to the outside world
resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"
  tags {
    CA001 = "${var.dept_mfk}"
  }
}

# Grant the VPC internet access on its main route table
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.default.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.default.id}"


}

# A security group for the web server
resource "aws_security_group" "web" {
  name        = "SPARC web server security group"
  description = "Used in the terraform"
  vpc_id      = "${aws_vpc.default.id}"

# SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
   # cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    CA001 = "${var.dept_mfk}"
  }
}

resource "aws_key_pair" "sparc_terraform" {
  key_name   = "Terraform key"
  public_key = "${file("~/.ssh/terraform.pub")}"

}

resource "aws_eip" "sparc_ip" {
  
  vpc = true
  tags {
    CA001 = "${var.dept_mfk}"
  }
}

# I need to separately associate the elastic IP with the
# instance instead of doing it when the EIP is created
# so that I don't have a  cyclical dependency between 
# the instance and the IP. The instance NEEDS to know the 
# IP of the EIP so that I can update my habitat config
resource "aws_eip_association" "sparc_web_ip_association" {
  instance_id = "${aws_instance.sparc_web.id}"
  allocation_id = "${aws_eip.sparc_ip.id}"
}

resource "aws_instance" "sparc_web" {

  connection {
    user = "ec2-user"
    private_key = "${file("~/.ssh/terraform")}"
  }
  ami           = "ami-0b1e356e"
  instance_type = "t2.micro"
  subnet_id     = "${aws_subnet.public_subnet.id}"
  vpc_security_group_ids = ["${aws_security_group.web.id}"]

  key_name = "${aws_key_pair.sparc_terraform.id}"

#   user_data = <<HEREDOC
# #!/bin/bash
# HEREDOC
  provisioner "local-exec" {
    command = "echo ${aws_instance.sparc_web.id} > sparc-web-instance.txt"
  }

  provisioner "local-exec" {
    command = "echo ${aws_eip.sparc_ip.public_ip} > sparc-web-ip.txt"
  }

  provisioner "local-exec" {
    command = "sed -e 's/REPLACE_PRIVATE_DB_HOST/${aws_db_instance.sparc_db.address}/g' -e 's/REPLACE_PUBLIC_WEB_HOST/${aws_eip.sparc_ip.public_ip}/g' files/sparc.habitat > files.computed/sparc.habitat"
  }

  provisioner "file" {
    # use_sudo = true
    source = "./files/sparc.nginx"
    destination = "/home/ec2-user/sparc.nginx"
    
  }

  provisioner "file" {
    # use_sudo = true
    source = "./files/nginx.yum"
    destination = "/home/ec2-user/nginx.repo"
    
  }

  # I could also use user_data for this script ...
  provisioner "remote-exec" {
    inline = [
      #Disable SELinux
      "sudo setenforce 0",
      "sudo mv /home/ec2-user/nginx.repo /etc/yum.repos.d/nginx.repo",
      "sudo yum update -y",
      "sudo yum install -y nginx",
      "sudo mv /home/ec2-user/sparc.nginx /etc/nginx/conf.d/default.conf",
      "sudo chown root:root /etc/nginx/conf.d/default.conf",
      "sudo chmod 0644 /etc/nginx/conf.d/default.conf",
      "sudo systemctl enable nginx",
      "sudo systemctl start nginx",
      "sudo mkdir -p /hab/svc/sparc-request/data"
      # Not doing this right now because the right version of the package
      # wont load the first time (see below)
      #"sudo touch /hab/svc/sparc-request/data/migrate"
    ]
  }

  provisioner "habitat" {
    use_sudo = true
    service_type = "systemd"
    service {
      name = "chrisortman/sparc-request"
      channel = "unstable"
      strategy = "at-once"
      user_toml = "${file("files.computed/sparc.habitat")}"
    }
  }

  ## This kinda temporary to fix up a bug in
  ## the habitat provisioner for terraform
  ## https://github.com/hashicorp/terraform/pull/17403/files

  provisioner "remote-exec" {
    inline = [
      "sudo hab svc unload chrisortman/sparc-request",
      "sudo touch /hab/svc/sparc-request/data/migrate",
      "sudo hab pkg install chrisortman/sparc-request --channel unstable",
      "sudo hab svc load chrisortman/sparc-request --channel unstable --strategy at-once",
      "sudo systemctl restart hab-supervisor"
    ]
  }


  tags {
    CA001 = "${var.dept_mfk}"
  }
}



