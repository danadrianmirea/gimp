#!/bin/sh

# Loosely based on:
# https://github.com/AppImage/AppImageSpec/blob/master/draft.md
# https://gitlab.com/inkscape/inkscape/-/commit/b280917568051872793a0c7223b8d3f3928b7d26

set -e

if [ -z "$GITLAB_CI" ]; then
  # Make the script work locally
  if [ "$0" != 'build/linux/appimage/2_bundle-gimp-appimage.sh' ] && [ ${PWD/*\//} != 'appimage' ]; then
    echo -e '\033[31m(ERROR)\033[0m: Script called from wrong dir. Please, call this script from the root of gimp git dir'
    exit 1
  elif [ ${PWD/*\//} = 'appimage' ]; then
    cd ../../..
  fi
fi


# SPECIAL BUILDING

## We apply these patches otherwise appstream-cli get confused with
## (non-reverse) DNS naming and fails. That's NOT a GIMP bug, see: #6798
echo '(INFO): patching GIMP with reverse DNS naming'
git apply -v build/linux/appimage/patches/0001-desktop-po-Use-reverse-DNS-naming.patch >/dev/null 2>&1
cd gimp-data
git apply -v ../build/linux/appimage/patches/0001-images-logo-Use-reverse-DNS-naming.patch >/dev/null 2>&1
cd ..

## Prepare env. Universal variables from .gitlab-ci.yml
IFS=$'\n' VAR_ARRAY=($(cat .gitlab-ci.yml | sed -n '/export PATH=/,/GI_TYPELIB_PATH}\"/p' | sed 's/    - //'))
IFS=$' \t\n'
for VAR in "${VAR_ARRAY[@]}"; do
  eval "$VAR" || continue
done

## Rebuild GIMP
echo '(INFO): rebuilding GIMP as relocatable'
### FIXME: GIMP tests fails with raster icons in relocatable mode
meson configure _build -Drelocatable-bundle=yes -Dvector-icons=true >/dev/null 2>&1
cd _build
ninja &> ninja.log | rm ninja.log || cat ninja.log
ninja install >/dev/null 2>&1
ccache --show-stats
cd ..


# INSTALL GO-APPIMAGETOOL
echo '(INFO): downloading go-appimagetool'
apt-get install -y --no-install-recommends wget >/dev/null 2>&1

## For now, we always use the latest version of go-appimagetool
wget -c https://github.com/$(wget -q https://github.com/probonopd/go-appimage/releases/expanded_assets/continuous -O - | grep "appimagetool-.*-x86_64.AppImage" | head -n 1 | cut -d '"' -f 2) >/dev/null 2>&1
mv *.AppImage appimagetool.appimage
go_appimagetool=appimagetool.appimage
chmod +x "$go_appimagetool"

## go-appimagetool have buggy appstreamcli so we need to use the legacy one
legacy_appimagetool="appimagetool-x86_64.AppImage"
wget "https://github.com/AppImage/AppImageKit/releases/download/continuous/$legacy_appimagetool" >/dev/null 2>&1
chmod +x "$legacy_appimagetool"


# BUNDLE FILES
echo '(INFO): copying files to AppDir'
UNIX_PREFIX='/usr'
if [ "$GITLAB_CI" ]; then
  export GIMP_PREFIX="$PWD/_install"
elif [ -z "$GITLAB_CI" ] && [ -z "$GIMP_PREFIX" ]; then
  export GIMP_PREFIX="$PWD/../_install"
fi
APP_DIR="$PWD/AppDir"
USR_DIR="$APP_DIR/usr"

prep_pkg ()
{
  apt-get install -y --no-install-recommends $1 >/dev/null 2>&1
}

bund_usr ()
{
  if [ -z "$3" ]; then
    cd $APP_DIR
    case $2 in
      bin*)
        mkdir -p $USR_DIR/bin
        find $1/bin -name ${2##*/} -execdir cp -r '{}' $USR_DIR/bin \;
        find /bin -name ${2##*/} -execdir cp -r '{}' $USR_DIR/bin \;
        ;;

      lib*)
        mkdir -p $USR_DIR/${LIB_DIR}/${LIB_SUBDIR}
        find $1/${LIB_DIR}/${LIB_SUBDIR} -maxdepth 1 -name ${2##*/} -execdir cp -r '{}' $USR_DIR/${LIB_DIR}/${LIB_SUBDIR} \;
        find /usr/${LIB_DIR} -maxdepth 1 -name ${2##*/} -execdir cp -r '{}' $USR_DIR/${LIB_DIR}/${LIB_SUBDIR} \;
        ;;

      libexec|share*|etc*)
        dat_path=$(echo $1/$2 | sed "s|$1/||g")
        dat_path_parent=$(echo $dat_path | sed "s|${dat_path##*/}||g")
        if [ -d "$1/$dat_path" ] || [ -f "$1/$dat_path" ]; then
          mkdir -p $USR_DIR/$dat_path_parent
          cp -r $1/$dat_path $USR_DIR/$dat_path_parent
        fi
        ;;
    esac
    cd ..
  fi
}

conf_app ()
{
  prefix=$UNIX_PREFIX
  case $1 in
    *BABL*|*GEGL*|*GIMP*)
      prefix=$GIMP_PREFIX
  esac
  var_path=$(echo $prefix/$2 | sed "s|${prefix}/||g")
  sed -i "s|${1}_WILD|usr/${var_path}|" build/linux/appimage/AppRun
}

wipe_usr ()
{
  if [[ ! "$1" =~ '*' ]]; then
    rm -r $USR_DIR/$1
  else
    cleanedArray=($(find $USR_DIR -iname ${1##*/}))
    for path_dest_full in "${cleanedArray[@]}"; do
      rm -r -f $path_dest_full
    done
  fi
}

## Prepare AppDir
if [ ! -f 'build/linux/appimage/AppRun.bak' ]; then
  cp build/linux/appimage/AppRun build/linux/appimage/AppRun.bak
fi
mkdir $APP_DIR
bund_usr "$UNIX_PREFIX" "lib64/ld-*.so.*" --go
conf_app LD_LINUX "lib64/ld-*.so.*"

## Bundle base (bare minimum to run GTK apps)
### Glib needed files (to be able to use file dialogs)
bund_usr "$UNIX_PREFIX" "share/glib-*/schemas"
### Glib commonly required modules
prep_pkg "gvfs"
bund_usr "$UNIX_PREFIX" "lib/gvfs*"
bund_usr "$UNIX_PREFIX" "lib/gio*"
conf_app GIO_MODULE_DIR "${LIB_DIR}/${LIB_SUBDIR}gio"
### GTK needed files (to be able to load icons)
bund_usr "$UNIX_PREFIX" "share/icons/Adwaita"
bund_usr "$GIMP_PREFIX" "share/icons/hicolor"
bund_usr "$UNIX_PREFIX" "share/mime"
bund_usr "$UNIX_PREFIX" "lib/gdk-pixbuf-*" --go
conf_app GDK_PIXBUF_MODULEDIR "${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/*.*.*"
conf_app GDK_PIXBUF_MODULE_FILE "${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/*.*.*"
### GTK commonly required modules
prep_pkg "libibus-1.0-5"
bund_usr "$UNIX_PREFIX" "lib/libibus*"
prep_pkg "ibus-gtk3"
prep_pkg "libcanberra-gtk3-module"
prep_pkg "libxapp-gtk3-module"
bund_usr "$UNIX_PREFIX" "lib/gtk-*" --go
conf_app GTK_PATH "${LIB_DIR}/${LIB_SUBDIR}gtk-3.0"
conf_app GTK_IM_MODULE_FILE "${LIB_DIR}/${LIB_SUBDIR}gtk-3.0/*.*.*"
### FIXME: GTK theming support (NOT WORKING)
#bund_usr "$UNIX_PREFIX" "bin/gsettings"

## Core features
bund_usr "$GIMP_PREFIX" "lib/libbabl*"
bund_usr "$GIMP_PREFIX" "lib/babl-*"
conf_app BABL_PATH "${LIB_DIR}/${LIB_SUBDIR}babl-*"
bund_usr "$GIMP_PREFIX" "lib/libgegl*"
bund_usr "$GIMP_PREFIX" "lib/gegl-*"
conf_app GEGL_PATH "${LIB_DIR}/${LIB_SUBDIR}gegl-*"
bund_usr "$GIMP_PREFIX" "lib/libgimp*"
bund_usr "$GIMP_PREFIX" "lib/gimp"
conf_app GIMP3_PLUGINDIR "${LIB_DIR}/${LIB_SUBDIR}gimp/*"
bund_usr "$GIMP_PREFIX" "share/gimp"
conf_app GIMP3_DATADIR "share/gimp/*"
lang_array=($(echo $(ls po/*.po |
              sed -e 's|po/||g' -e 's|.po||g' | sort) |
              tr '\n\r' ' '))
for lang in "${lang_array[@]}"; do
  bund_usr "$GIMP_PREFIX" share/locale/$lang/LC_MESSAGES
  #bund_usr "$UNIX_PREFIX" share/locale/$lang/LC_MESSAGES/gtk*.mo
  # For language list in text tool options
  bund_usr "$UNIX_PREFIX" share/locale/$lang/LC_MESSAGES/iso_639_3.mo
done
conf_app GIMP3_LOCALEDIR "share/locale"
bund_usr "$GIMP_PREFIX" "etc/gimp"
conf_app GIMP3_SYSCONFDIR "etc/gimp/*"

## Other features and plug-ins
### Needed for welcome page
bund_usr "$GIMP_PREFIX" "share/metainfo/org.gimp*.xml"
sed -i '/kudo/d' $USR_DIR/share/metainfo/org.gimp.GIMP.appdata.xml
sed -i "s/date=\"TODO\"/date=\"`date --iso-8601`\"/" $USR_DIR/share/metainfo/org.gimp.GIMP.appdata.xml
### mypaint brushes
bund_usr "$UNIX_PREFIX" "share/mypaint-data/1.0"
### Needed for full CJK and Cyrillic support in file-pdf
bund_usr "$UNIX_PREFIX" "share/poppler"
### FIXME: file-wmf (NOT WORKING for exporting)
#bund_usr "$UNIX_PREFIX" "share/libwmf"
### FIXME: Image graph support (NOT WORKING)
#bund_usr "$UNIX_PREFIX" "bin/dot"
#bund_usr "$UNIX_PREFIX" "lib/graphviz"
### Needed for GTK inspector
bund_usr "$UNIX_PREFIX" "lib/libEGL*"
bund_usr "$UNIX_PREFIX" "lib/libGL*"
bund_usr "$UNIX_PREFIX" "lib/dri*"
conf_app LIBGL_DRIVERS_PATH "${LIB_DIR}/${LIB_SUBDIR}dri"
### FIXME: Debug dialog (NOT WORKING)
#bund_usr "$UNIX_PREFIX" "bin/lldb*"
#bund_usr "$GIMP_PREFIX" "libexec/gimp-debug-tool*"
### Introspected plug-ins
bund_usr "$GIMP_PREFIX" "lib/girepository-*"
bund_usr "$UNIX_PREFIX" "lib/girepository-*"
conf_app GI_TYPELIB_PATH "${LIB_DIR}/${LIB_SUBDIR}girepository-*"
#### JavaScript plug-ins support
bund_usr "$UNIX_PREFIX" "bin/gjs"
#### Python plug-ins support
bund_usr "$UNIX_PREFIX" "bin/python*"
bund_usr "$UNIX_PREFIX" "lib/python*"
mv "$USR_DIR/${LIB_DIR}/${LIB_SUBDIR}python3.11" "$USR_DIR/${LIB_DIR}"
mv "$USR_DIR/${LIB_DIR}/${LIB_SUBDIR}python3" "$USR_DIR/${LIB_DIR}"
wipe_usr ${LIB_DIR}/*.pyc
#### FIXME: Lua plug-ins support (NOT WORKING)
#bund_usr "$UNIX_PREFIX" "bin/luajit*"
#bund_usr "$UNIX_PREFIX" "lib/lua"
#bund_usr "$UNIX_PREFIX" "share/lua"

## Other binaries and deps
bund_usr "$GIMP_PREFIX" 'bin/gimp*'
bund_usr "$GIMP_PREFIX" "bin/gegl"
bund_usr "$GIMP_PREFIX" "share/applications/org.gimp.GIMP.desktop"
"./$go_appimagetool" --appimage-extract-and-run -s deploy $USR_DIR/share/applications/org.gimp.GIMP.desktop &> appimagetool.log

## Manual adjustments (go-appimagetool don't handle these things gracefully)
### Undo the mess that go-appimagetool makes on the prefix which breaks babl and gegl)
cp -r $APP_DIR/lib64 $USR_DIR
rm -r $APP_DIR/lib64
cp -r $APP_DIR/lib/* $USR_DIR/${LIB_DIR}
rm -r $APP_DIR/lib
### Remove unnecessary files bunbled by go-appimagetool
wipe_usr ${LIB_DIR}/${LIB_SUBDIR}gconv
wipe_usr ${LIB_DIR}/${LIB_SUBDIR}gdk-pixbuf-*/gdk-pixbuf-query-loaders
wipe_usr share/doc
wipe_usr share/themes
rm -r $APP_DIR/etc


# FINISH APPIMAGE

## Configure AppRun
echo '(INFO): configuring AppRun'
GIMP_APP_VERSION=$(grep GIMP_APP_VERSION _build/config.h | head -1 | sed 's/^.*"\([^"]*\)"$/\1/')
sed -i "s|GIMP_APP_VERSION|${GIMP_APP_VERSION}|" build/linux/appimage/AppRun
sed -i "s|DEBIAN_VERSION|$(cat /etc/debian_version)|" build/linux/appimage/AppRun
mv build/linux/appimage/AppRun $APP_DIR
chmod +x $APP_DIR/AppRun
mv build/linux/appimage/AppRun.bak build/linux/appimage/AppRun

## Copy icon to proper place
echo "(INFO): copying org.gimp.GIMP.svg asset to AppDir"
cp $GIMP_PREFIX/share/icons/hicolor/scalable/apps/org.gimp.GIMP.svg $APP_DIR/org.gimp.GIMP.svg

## Construct .appimage
gimp_version=$(grep GIMP_VERSION _build/config.h | head -1 | sed 's/^.*"\([^"]*\)"$/\1/')
appimage="GIMP-${gimp_version}-$(uname -m).AppImage"
echo "(INFO): making $appimage"
ARCH=$(uname -m) "./$legacy_appimagetool" --appimage-extract-and-run $APP_DIR &>> appimagetool.log # -u "zsync|https://download.gimp.org/gimp/v${GIMP_APP_VERSION}/GIMP-latest-$(uname -m).AppImage.zsync"
mv GNU*.AppImage $appimage
rm -r $APP_DIR

if [ "$GITLAB_CI" ]; then
  mkdir -p build/linux/appimage/_Output/
  mv GIMP*.AppImage build/linux/appimage/_Output/
  mv *.log build/linux/appimage/_Output/
fi
