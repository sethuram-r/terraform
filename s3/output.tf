
output "secret" {
  value = aws_iam_access_key.smartshare.secret   # just for reference  must be deleted
}

output "access_key" {
  value = aws_iam_access_key.smartshare.id        # just for reference  must be deleted
}