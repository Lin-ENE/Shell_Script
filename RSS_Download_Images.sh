#!/bin/bash
echo "----------脚本执行开始----------"
    date
# 保存路径
    save_path=

echo "----------检测保存路径----------"
    if [ -e "${save_path}" ]
    then
        echo "保存路径为${save_path}"
    else
        echo "创建保存路径${save_path}"
        mkdir ${save_path}
        echo "保存路径为${save_path}"
    fi
# rss订阅地址
    rss_url=

# 下载订阅信息
echo "----------下载订阅----------"
    wget ${rss_url} -O ${save_path}/rss.xml

echo "----------计算文章数量----------"
    # 计算一共有多少条
    description_cont=`cat ${save_path}/rss.xml | grep '<description>' | wc -l`
    # 计算正确一共有几条
    description_cont_True=`expr ${description_cont} - 1`
    # 输出计算结果
    echo "共有${description_cont_True}条文章"

echo "----------创建类别文件夹----------"
    # 判断类别文件夹是否创建
    if [ -e "${save_path}/漫画" ]
    then
        echo "漫画类别文件夹已创建"
    else
        mkdir "${save_path}/漫画"
    fi

    if [ -e "${save_path}/漫画素材工房" ]
    then
        echo "漫画素材工房类别文件夹已创建"
    else
        mkdir "${save_path}/漫画素材工房"
    fi

    if [ -e "${save_path}/本子" ]
    then
        echo "本子类别文件夹已创建"
    else
        mkdir "${save_path}/本子"
    fi

echo "----------开始下载----------"
# 从第二条开始下载，第一条为网页信息
    i=2
# 下载循环开始
    until [ ! $i -le ${description_cont} ]
    do
        # description_title=`cat ${save_path}/rss.xml | grep '<description>' | sed -n ${i}p | sed 's/.*<\!\[CDATA\[<p>\(.*\)<\/p><br><p><img.*/\1/g'`
        # description_title=`cat ${save_path}/rss.xml | sed ':a;N;$!ba;s/\(.*<\/title>\)\n/\1/g' | sed ':a;N;$!ba;s/\(.*<\/link>\)\n/\1/g' | sed ':a;N;$!ba;s/\(.*<\/dc:creator>\)\n/\1/g' | grep '<description>' | sed -n ${i}p | sed 's/.*<\!\[CDATA\[<p>\(.*\)<\/p><br><p><img.*/\1/g'`
        # 获取标题名称
        description_title=`cat ${save_path}/rss.xml | grep '<title>'  | sed -n ${i}p | sed 's/<title>\(.*\)<\/title>/\1/g' | sed 's/#[0-9]\{1,2\}[[:space:]]*//g' | sed 's/^[[:space:]]*//g'`
        descriptio_creator=`cat ${save_path}/rss.xml | egrep -o '<dc:creator>.+' | sed -n ${i}p | sed 's/<dc:creator>\(.*\)<\/dc:creator>/\1/g' | sed 's/#[0-9]\{1,2\}[[:space:]]*//g' | sed 's/^[[:space:]]*//g'`
        descriptio_category=`cat ${save_path}/rss.xml  | sed ':a;N;s/<\/dc:creator>\n.*\(<category>漫画.*<\/category>\)/<\/dc:creator>\1/g' | egrep -o '<dc:creator>.+' | sed -n ${i}p | sed 's/<dc:creator>\(.*\)<\/dc:creator>//g' | sed 's/#[0-9]\{1,2\}[[:space:]]*//g' | sed 's/^[[:space:]]*//g' | sed 's/<category>\(.*\)<\/category>/\1/g'`

        # 检测类别
        if [ -e ${descriptio_category} ]
        then
            echo "无特别分类"
            save_path_category=${save_path}/本子
        else
            case ${descriptio_category} in
                "漫画")
                echo "漫画分类"
                save_path_category=${save_path}/漫画
                    ;;
                "漫画素材工房")
                echo "漫画素材工房分类"
                save_path_category=${save_path}/漫画素材工房
                    ;;
            esac
        fi

        # 检测作者和标题文件夹是否存在
        if [ -e "${save_path_category}/${descriptio_creator}" ]
        then
            echo "作者文件夹已存在"
        else
            mkdir "${save_path_category}/${descriptio_creator}"
        fi
        
        if [ -e "${save_path_category}/${descriptio_creator}/${description_title}" ]
        then
            echo "标题文件夹已存在"
        else
            mkdir "${save_path_category}/${descriptio_creator}/${description_title}"
        fi
        echo -e "正在下载第${i}个，${descriptio_creator} 创作的 ${description_title}\n"
        # 获取图片地址
        # description_imgurl=`cat ${save_path}/rss.xml | grep '<description>' | sed -n ${i}p | egrep -o "https.+(jpg|png)\"" | sed 's/" referrerpolicy="no-referrer"><\/p><p><img src="/ /g' | sed 's/"$//g'`
        description_imgurl=`cat ${save_path}/rss.xml | grep '<description>' | sed -n ${i}p | egrep -o "https.+\"" | sed 's/" referrerpolicy="no-referrer"><\/p><p><img src="/ /g' | sed 's/" referrerpolicy="no-referrer"//g'`
        # 下载图片
        wget -N ${description_imgurl} -P "${save_path_category}/${descriptio_creator}/${description_title}/" 2>> "${save_path}/wget-error.log"
        # 
        i=`expr $i + 1`
    done

echo "----------删除订阅文件----------"
    rm ${save_path}/rss.xml

echo "----------移动当前目录下图片----------"
    if [ -e "${save_path}/侠名" ]
    then
        echo ""
    else
        echo "创建保存路径${save_path}/侠名"
        mkdir ${save_path}/侠名
    fi
    mv ${save_path}/*.jpg "${save_path}/侠名/"
    mv ${save_path}/*.png "${save_path}/侠名/"
    mv ${save_path}/*.gif "${save_path}/侠名/"

echo "----------脚本执行结束----------"
echo -e '\n\n'