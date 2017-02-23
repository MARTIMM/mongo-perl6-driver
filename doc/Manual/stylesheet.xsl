<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE stylesheet [
<!ENTITY infin "&#x221E;">
<!ENTITY nbsp " ">
<!ENTITY mongodb "MongoDB driver">
]>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:import href="/usr/share/sgml/docbook/xsl-ns-stylesheets/fo/docbook.xsl"/>
  <xsl:param name="paper.type" select="'A4'"/>
  <xsl:param name="chapter.autolabel" select="1"/>
  <xsl:param name="appendix.autolabel" select="'A'"/>
  <xsl:param name="section.autolabel" select="1"/>
  <xsl:param name="section.label.includes.component.label" select="1"/>
  <xsl:param name="section.autolabel.max.depth" select="3"/>
  <xsl:param name="insert.xref.page.number" select="'yes'"/>
  <xsl:param name="callout.graphics" select="1"/>
  <xsl:param name="callout.graphics.path" select="'/home/marcel/Graphics/IconsArchive/Icons/Scalable/Docbook/Svg/'"/>
  <xsl:param name="callout.graphics.extension" select="'.svg'"/>
  <xsl:param name="callout.graphics.number.limit" select="20"/>
  <xsl:param name="callout.icon.size" select="14"/>
  <xsl:param name="admon.graphics" select="1"/>
  <xsl:param name="admon.graphics.path" select="'/home/marcel/Graphics/IconsArchive/Icons/32x32/Docbook/'"/>
  <xsl:param name="admon.graphics.extension" select="'.png'"/>
  <xsl:attribute-set name="xref.properties">
    <xsl:attribute name="color">
      <xsl:choose>
        <xsl:when test="self::link">blue</xsl:when>
        <xsl:otherwise>inherit</xsl:otherwise>
      </xsl:choose>
    </xsl:attribute>
  </xsl:attribute-set>
</xsl:stylesheet>
