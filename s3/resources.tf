resource "aws_iam_user" "smartshare" {
  name = var.bucket_name
  path = "/user/"
  permissions_boundary="arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_user_policy_attachment" "smartshare-policy" {
  user       = aws_iam_user.smartshare.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_access_key" "smartshare" {
  user = aws_iam_user.smartshare.name
}