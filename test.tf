

// Describing provider
provider "aws"{
    region     = "ap-south-1"
    profile    = "ajprofile"
}

// Creating Key 
resource "tls_private_key" "tls_key" {
    algorithm   = "RSA"
}

// Generating key-value pair
resource "aws_key_pair" "web-key"{
    depends_on = [
        tls_private_key.tls_key
    ]
    key_name   = "web-env-key"
    public_key = tls_private_key.tls_key.public_key_openssh
}

// Saving private key in PEM file 
resource "local_file" "web-key-file" {
    depends_on = [
    tls_private_key.tls_key
    ]
    content     = tls_private_key.tls_key.private_key_pem
    filename =  "web-env-key.pem"
}

// Creating security grop
resource "aws_security_group" "web-SSH-SG" {
    name        = "web-env-SSH-SG"
    description = "Security Group for web environment"

  // Adding inbound rules in security groups
    ingress {
        description = "HTTP Rule"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        description = "SSH Rule"
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

//Creating a S3 Bucket
resource "aws_s3_bucket" "web-bucket" {
    bucket = "aj-web-bucket"
    acl    = "public-read"
    tags = {
        Name = "web-s3-bucket"
    }
}

//Putting Objects in S3 Bucket
resource "aws_s3_bucket_object" "web-object1" {
    bucket = aws_s3_bucket.web-bucket.bucket
    key    = "img1.jpg"
    source = "img1.jpg"
    acl    = "public-read"
 }

    //Creating CloutFront with S3 Bucket Origin
resource "aws_cloudfront_distribution" "s3-web-distribution" {
    depends_on = [
        aws_s3_bucket.web-bucket
    ]
    origin {
        domain_name = aws_s3_bucket.web-bucket.bucket_regional_domain_name
        origin_id   = aws_s3_bucket.web-bucket.id
    }
    enabled             = true
    is_ipv6_enabled     = true
    comment             = "S3 Web Distribution"
    default_cache_behavior {
        allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
        cached_methods   = ["GET", "HEAD"]
        target_origin_id = aws_s3_bucket.web-bucket.id

    forwarded_values {
        query_string = false
        cookies {
            forward = "none"
        }
        }
        viewer_protocol_policy = "allow-all"
        min_ttl                = 0
        default_ttl            = 3600
        max_ttl                = 86400
    }
    restrictions {
        geo_restriction {
        restriction_type = "whitelist"
        locations        = ["IN"]
        }
    }
    tags = {
        Name        = "Web-CF-Distribution"
        Environment = "Production"
    }
    viewer_certificate {
        cloudfront_default_certificate = true
    }
}

//Launching EC2 Instance
resource "aws_instance" "web-OS" {
    ami           = "ami-0447a12f28fddb066"
    instance_type = "t2.micro"
    key_name        = aws_key_pair.web-key.key_name
    security_groups = [ aws_security_group.web-SSH-SG.name,"default" ]


    //Labelling the Instance
    tags = {
        Name = "Web-Env"
        env  = "Production"
    }

    volume_tags = {
        Name = "web-Volume"
    }
    provisioner "local-exec" {
        command = "sed -i 's/CF_URL/${aws_cloudfront_distribution.s3-web-distribution.domain_name}/g' web.html"
    }

    provisioner "file" {
        connection {
        agent       = false
        type        = "ssh"
        user        = "ec2-user"
        private_key = tls_private_key.tls_key.private_key_pem
        host        = aws_instance.web-OS.public_ip
        }


    source      = "web.html"
    destination = "/home/ec2-user/web.html" 
    }

    //Executing Commands to initiate WebServer in Instance Over SSH 
    provisioner "remote-exec" {
        connection {
            agent       = "false"
            type        = "ssh"
            user        = "ec2-user"
            private_key = tls_private_key.tls_key.private_key_pem
            host        = aws_instance.web-OS.public_ip
        }

        inline = [
            "sudo yum install httpd git -y",
            "sudo systemctl start httpd",
            "sudo systemctl enable httpd",
        ]
    }


    //Storing Key and IP in Local Files
    provisioner "local-exec" {
        command = "echo ${aws_instance.web-OS.public_ip} > public-ip.txt"
    }
    depends_on = [
        aws_security_group.web-SSH-SG,
        aws_key_pair.web-key
    ]
}


//Creating EBS Volume
resource "aws_ebs_volume" "web-vol" {
    availability_zone = aws_instance.web-OS.availability_zone
    size              = 1
    
    tags = {
        Name = "persistent-ebs-vol"
    }
}


//Attaching EBS Volume to a Instance
resource "aws_volume_attachment" "ebs-att" {
    device_name  = "/dev/sdh"
    volume_id    = aws_ebs_volume.web-vol.id
    instance_id  = aws_instance.web-OS.id
    force_detach = true


    provisioner "remote-exec" {
        connection {
        agent       = "false"
        type        = "ssh"
        user        = "ec2-user"
        private_key = tls_private_key.tls_key.private_key_pem
        host        = aws_instance.web-OS.public_ip
        }
    
        inline = [
        "sudo mkfs.ext4 /dev/xvdh",
        "sudo mount /dev/xvdh /var/www/html/",
        "sudo rm -rf /var/www/html/*",
        "sudo mkdir aaa",
        //"sudo git clone https://github.com/ajtechy/Terraform-cloud-task1.git",
        //"sudo mkdir bbb",
        //"sudo cp /home/ec2-user/Terraform-cloud-task1/web.html  /var/www/html/",
        //"sudo cp /home/ec2-user/Terraform-cloud-task1/img1.jpg  /var/www/html/",
        "sudo cp /home/ec2-user/web.html /var/www/html/"
        ]
    }
    depends_on = [
        aws_instance.web-OS,
        aws_ebs_volume.web-vol
    ]
}

//Creating EBS Snapshot
resource "aws_ebs_snapshot" "ebs-snapshot" {
    volume_id   = aws_ebs_volume.web-vol.id
    description = "Snapshot of our EBS volume"
    
    tags = {
        env = "Production"
    }
    depends_on = [
        aws_volume_attachment.ebs-att
    ]
}  


output "s3-detail"{
    value = aws_s3_bucket_object.web-object1
    
}
output "s31-detail"{
    value = aws_s3_bucket.web-bucket
}
output "CF-detail"{
    value = aws_cloudfront_distribution.s3-web-distribution
}



