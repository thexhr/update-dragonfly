#!/bin/sh

d=`mktemp -d /tmp/updfly.XXXX`
ud=update-dragonfly
cvsid=matthias@globus.mathematik.uni-marburg.de:/cvs
remote=schmidtm@login.mathematik.uni-marburg.de:.www/update-dragonfly

cd /tmp

if [ -d $ud ]; then
	rm -I -rf $ud
	rm $ud.tar*
fi

echo "Check out latest source"
cvs -d $cvsid co $ud || return
echo "Create distrib package"
mv $ud/client/* $d
rm -r $ud
mv $d $ud
rm -r $ud/CVS
rm -f $ud/*.swp
echo "Create tarball"
tar cf $ud.tar $ud || return
gzip -9 $ud.tar || return
echo ""
tar tfvz $ud.tar.gz
echo ""
echo "scp /tmp/$ud.tar.gz $remote"
