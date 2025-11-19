FROM public.ecr.aws/nginx/nginx:alpine

# デフォルトのHTMLファイルを確実に削除し、我々のファイルだけが存在するようにします
RUN rm -f /usr/share/nginx/html/*

# 我々のindex.htmlをコピーします
COPY index.html /usr/share/nginx/html/