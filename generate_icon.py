from PIL import Image, ImageDraw
sizes = [16,32,48,256]
# Create a wifi symbol icon with gradient background
for size in sizes:
    img = Image.new('RGBA', (size, size), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # background gradient
    for y in range(size):
        t = y / float(size-1)
        r = int(34 + t*(88-34))
        g = int(15 + t*(40-15))
        b = int(98 + t*(170-98))
        draw.line([(0,y),(size,y)], fill=(r,g,b))
    # wifi arcs
    center = (size//2, int(size*0.45))
    max_r = int(size*0.35)
    arc_width = max(1, size//12)
    for i in range(3):
        r = max_r - i*(size//10)
        bbox = [center[0]-r, center[1]-r, center[0]+r, center[1]+r]
        draw.arc(bbox, start=200, end=340, fill=(255,255,255,255), width=arc_width)
    # dot
    dot_r = max(1, size//18)
    dot_center = (center[0], center[1]+int(size*0.34))
    draw.ellipse([dot_center[0]-dot_r, dot_center[1]-dot_r, dot_center[0]+dot_r, dot_center[1]+dot_r], fill=(255,255,255,255))
    img.save(f"wifi_{size}.png")
# Combine into .ico
imgs = [Image.open(f"wifi_{s}.png").convert('RGBA') for s in sizes]
imgs[0].save('wifi_icon.ico', format='ICO', sizes=[(s,s) for s in sizes])
print('ICON_CREATED')
