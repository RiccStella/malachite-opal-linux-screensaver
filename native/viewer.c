/* Malachite Opal by Riccardo Stella (Alchemist). Native GTK/OpenGL viewer.
 * Decorative pre-lock artwork only. No lock, input grabs or idle inhibitors. */
#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <glib-unix.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include "shader.h"

static GLuint program, vao, vbo, scaled_fbo, scaled_texture;
static int scaled_width, scaled_height;
static GLint resolution_location, time_location;
static gint64 started;
static int status_code, frames, smoke_frames;
static double fixed_time = -1;
static const char *capture_path;
static GtkWidget *window, *area;
static gboolean pointer_known;
static double pointer_x, pointer_y;
static guint timer_id;
static const char *vertex_source = "#version 150\nin vec2 a_position;\nvoid main(){gl_Position=vec4(a_position,0.0,1.0);}";

static gboolean quit(gpointer unused) {
    (void)unused;
    gtk_main_quit();
    return G_SOURCE_REMOVE;
}
static void destroyed(GtkWidget *widget, gpointer unused) {
    (void)widget; (void)unused;
    if (gtk_main_level() > 0) gtk_main_quit();
    window = NULL;
}
static void fail(const char *message) {
    fprintf(stderr, "Malachite Opal: %s\n", message);
    status_code = 1;
    g_idle_add(quit, NULL);
}
static GLuint compile(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[8192];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fail(log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}
static float hue(float h) {
    h = h - floorf(h);
    if (h < 1.f/6.f) return h * 6;
    if (h < .5f) return 1;
    if (h < 2.f/3.f) return (2.f/3.f-h)*6;
    return 0;
}
static void color(const char *name, double h) {
    glUniform3f(glGetUniformLocation(program, name), hue(h+1./3), hue(h), hue(h-1./3));
}
static void realize(GtkGLArea *widget, gpointer unused) {
    (void)unused;
    gtk_gl_area_make_current(widget);
    GError *error = gtk_gl_area_get_error(widget);
    if (error) { fail(error->message); return; }
    fprintf(stderr, "GL_RENDERER: %s\nGL_VERSION: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    if (strstr(renderer, "llvmpipe") || strstr(renderer, "softpipe") || strstr(renderer, "SwiftShader"))
        fprintf(stderr, "WARNING: software rendering; CPU usage may be high.\n");
    GLuint vs = compile(GL_VERTEX_SHADER, vertex_source), fs = compile(GL_FRAGMENT_SHADER, fragment_source);
    if (!vs || !fs) { if(vs) glDeleteShader(vs); if(fs) glDeleteShader(fs); return; }
    program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "a_position");
    glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { char log[8192]; glGetProgramInfoLog(program, sizeof(log), NULL, log); fail(log); return; }
    glUseProgram(program);
    const float positions[] = {-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1};
    glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,NULL);
    double center = g_random_double(), range = g_random_double();
    color("colorA", center); color("colorB", center+range); color("colorC", center-range);
    glUniform1f(glGetUniformLocation(program,"tentacleCount"), g_random_int_range(2,13));
    glUniform1f(glGetUniformLocation(program,"blobSeed"), g_random_int_range(10,100));
    resolution_location = glGetUniformLocation(program,"iResolution");
    time_location = glGetUniformLocation(program,"iTime");
    glDisable(GL_DEPTH_TEST); glDisable(GL_BLEND);
}
static void unrealize(GtkGLArea *widget, gpointer unused) {
    (void)unused;
    gtk_gl_area_make_current(widget);
    if (!gtk_gl_area_get_error(widget)) {
        glDeleteFramebuffers(1,&scaled_fbo); glDeleteTextures(1,&scaled_texture);
        glDeleteBuffers(1,&vbo); glDeleteVertexArrays(1,&vao); glDeleteProgram(program);
    }
}
static gboolean render(GtkGLArea *widget, GdkGLContext *context, gpointer unused) {
    (void)context; (void)unused;
    if (!program || status_code) return TRUE;
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(widget));
    int width = gtk_widget_get_allocated_width(GTK_WIDGET(widget))*scale;
    int height = gtk_widget_get_allocated_height(GTK_WIDGET(widget))*scale;
    if (width <= 0 || height <= 0) return TRUE;
    int render_width = width/scale, render_height = height/scale;
    GLint target;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &target);
    if (scale > 1) {
        if (!scaled_fbo) {glGenFramebuffers(1,&scaled_fbo); glGenTextures(1,&scaled_texture);}
        glBindFramebuffer(GL_FRAMEBUFFER,scaled_fbo);
        glBindTexture(GL_TEXTURE_2D,scaled_texture);
        if (render_width!=scaled_width || render_height!=scaled_height) {
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,render_width,render_height,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,scaled_texture,0);
            scaled_width=render_width; scaled_height=render_height;
        }
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) {fail("Scaled framebuffer incomplete"); return TRUE;}
    }
    glViewport(0,0,render_width,render_height);
    glUseProgram(program); glBindVertexArray(vao);
    glUniform2f(resolution_location,render_width,render_height);
    glUniform1f(time_location,fixed_time >= 0 ? fixed_time : (g_get_monotonic_time()-started)/1000000.);
    glDrawArrays(GL_TRIANGLES,0,6);
    if (scale > 1) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER,scaled_fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,(GLuint)target);
        glBlitFramebuffer(0,0,render_width,render_height,0,0,width,height,GL_COLOR_BUFFER_BIT,GL_LINEAR);
        glBindFramebuffer(GL_FRAMEBUFFER,(GLuint)target);
    }
    if (glGetError()!=GL_NO_ERROR) { fail("OpenGL draw failed"); return TRUE; }
    frames++;
    if (smoke_frames && frames >= smoke_frames) {
        /* Readback only in explicit test mode, never in ordinary animation. */
        unsigned char *pixels = g_malloc((gsize)width*height*3);
        glPixelStorei(GL_PACK_ALIGNMENT,1);
        glReadPixels(0,0,width,height,GL_RGB,GL_UNSIGNED_BYTE,pixels);
        unsigned char low=255, high=0;
        for(gsize i=0;i<(gsize)width*height*3;i++) {low=MIN(low,pixels[i]); high=MAX(high,pixels[i]);}
        if (glGetError()!=GL_NO_ERROR || high-low<10) fail("Smoke render was empty or uniform");
        else fprintf(stderr,"NATIVE_SMOKE_OK frames=%d size=%dx%d range=%d\n",frames,width,height,high-low);
        if(capture_path) {
            FILE *f=fopen(capture_path,"wb");
            if(!f) fail("Cannot write capture");
            else {fprintf(f,"P6\n%d %d\n255\n",width,height); for(int y=height-1;y>=0;y--) fwrite(pixels+(gsize)y*width*3,3,width,f); fclose(f);}
        }
        g_free(pixels); g_idle_add(quit,NULL);
    }
    return TRUE;
}
static gboolean tick(gpointer unused) {
    (void)unused;
    gtk_gl_area_queue_render(GTK_GL_AREA(area));
    return G_SOURCE_CONTINUE;
}
static gboolean input(GtkWidget *widget, GdkEvent *event, gpointer unused) {
    (void)widget; (void)unused;
    if(smoke_frames) return FALSE;
    if(event->type == GDK_MOTION_NOTIFY) {
        GdkEventMotion *motion=(GdkEventMotion *)event;
        if(!pointer_known) {pointer_x=motion->x_root;pointer_y=motion->y_root;pointer_known=TRUE;return FALSE;}
        if(fabs(motion->x_root-pointer_x)<2 && fabs(motion->y_root-pointer_y)<2) return FALSE;
    }
    gtk_main_quit(); return TRUE;
}
int main(int argc,char **argv) {
    int fps=30, duration=60;
    gboolean windowed=FALSE;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--windowed")) windowed=TRUE;
        else if(i+1<argc && !strcmp(argv[i],"--smoke-frames")) smoke_frames=atoi(argv[++i]);
        else if(i+1<argc && !strcmp(argv[i],"--capture")) capture_path=argv[++i];
        else if(i+1<argc && !strcmp(argv[i],"--time")) fixed_time=g_ascii_strtod(argv[++i],NULL);
        else if(i+1<argc && !strcmp(argv[i],"--seed")) g_random_set_seed((guint32)g_ascii_strtoull(argv[++i],NULL,10));
        else if(i+1<argc && !strcmp(argv[i],"--fps")) fps=atoi(argv[++i]);
        else if(i+1<argc && !strcmp(argv[i],"--duration")) duration=atoi(argv[++i]);
        else {fprintf(stderr,"Usage: viewer [--windowed] [--fps 1..60] [--duration 1..60] [--seed N] [--time S] [--smoke-frames N --capture FILE]\n");return 2;}
    }
    if(fps<1 || fps>60 || duration<1 || duration>60 || smoke_frames<0 || !isfinite(fixed_time)) return 2;
    if(!gtk_init_check(NULL,NULL)) {fprintf(stderr,"Cannot connect to desktop display\n");return 1;}
    window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window),"Malachite Opal");
    gtk_window_set_default_size(GTK_WINDOW(window),640,360);
    gtk_window_set_decorated(GTK_WINDOW(window),windowed);
    area=gtk_gl_area_new();
    gtk_gl_area_set_required_version(GTK_GL_AREA(area),3,2);
    gtk_gl_area_set_has_alpha(GTK_GL_AREA(area),FALSE);
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(area),FALSE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area),FALSE);
    gtk_container_add(GTK_CONTAINER(window),area);
    gtk_widget_add_events(window,GDK_POINTER_MOTION_MASK|GDK_BUTTON_PRESS_MASK|GDK_KEY_PRESS_MASK|GDK_SCROLL_MASK);
    g_signal_connect(area,"realize",G_CALLBACK(realize),NULL);
    g_signal_connect(area,"unrealize",G_CALLBACK(unrealize),NULL);
    g_signal_connect(area,"render",G_CALLBACK(render),NULL);
    g_signal_connect(window,"destroy",G_CALLBACK(destroyed),NULL);
    g_signal_connect(window,"key-press-event",G_CALLBACK(input),NULL);
    g_signal_connect(window,"button-press-event",G_CALLBACK(input),NULL);
    g_signal_connect(window,"motion-notify-event",G_CALLBACK(input),NULL);
    g_signal_connect(window,"scroll-event",G_CALLBACK(input),NULL);
    started=g_get_monotonic_time();
    if(!windowed) gtk_window_fullscreen(GTK_WINDOW(window));
    gtk_widget_show_all(window);
    GdkWindow *gwindow=gtk_widget_get_window(window);
    GdkCursor *cursor=gdk_cursor_new_for_display(gdk_window_get_display(gwindow),GDK_BLANK_CURSOR);
    gdk_window_set_cursor(gwindow,cursor); g_object_unref(cursor);
    timer_id=g_timeout_add((1000+fps-1)/fps,tick,NULL);
    g_timeout_add_seconds(duration,quit,NULL);
    g_unix_signal_add(SIGTERM,quit,NULL); g_unix_signal_add(SIGINT,quit,NULL);
    gtk_main();
    g_source_remove(timer_id);
    if (window) gtk_widget_destroy(window);
    return status_code;
}
