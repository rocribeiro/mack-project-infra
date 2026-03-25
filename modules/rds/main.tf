# modules/rds/main.tf

# 1. Grupo de Segurança (Firewall) para permitir a conexão no banco
resource "aws_security_group" "rds_sg" {
  name        = "b3-datalake-dev-rds-sg"
  description = "Permite acesso ao PostgreSQL da camada SPEC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Acesso ao PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # ALERTA MBA: Liberado para vocês testarem de casa. Em produção, isso seria restrito!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. A Instância do Banco de Dados (PostgreSQL)
resource "aws_db_instance" "spec_db" {
  identifier             = "b3-datalake-dev-spec"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro" # Máquina do nível gratuito (Free Tier)
  allocated_storage      = 20            # 20 GB de espaço (Suficiente para o projeto)
  
  db_name                = "b3_spec"
  username               = "admin_mack"
  password               = "CaioJonasJulioRodrigo" 
  
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = var.db_subnet_group_name
  
  publicly_accessible    = true # Fundamental para vocês conectarem do DBeaver/pgAdmin localmente
  skip_final_snapshot    = true # Permite destruir o banco rapidamente sem gerar backup (ótimo para testes)
}

# 3. Output para mostrar o endereço do banco quando terminar
output "db_endpoint" {
  value = aws_db_instance.spec_db.endpoint
}